#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Exercises the cask's uninstall_preflight guard. Driven by test/test-cask-guard.sh,
# which renders the cask first and passes its path as ARGV[0].
#
# The block under test is EXTRACTED from the rendered cask rather than retyped here, so
# this cannot drift from what ships. That matters more than usual: the guard is Ruby
# living inside a shell heredoc in make-cask.sh, where an unescaped backtick or dollar
# sign is eaten by the shell and never reported. A copy in this file would keep passing
# while the shipped cask was mangled.
#
# Homebrew is not available on the machine that runs this — and installing a cask to
# test an uninstall guard is not a test, it is an uninstall. So the two things the block
# borrows from Homebrew's DSL are shimmed: system_command, and Cask::CaskError. The pid
# file is shimmed too, because /var/run needs root and a test must never depend on the
# state of a real tunnel.
#
# The pids are real. The EPERM case is the entire reason this guard can be trusted, and
# only a live root-owned process exercises it.

module Cask
  class CaskError < RuntimeError; end
end

PID_FILE = "/var/run/anyway-connect.pid"

$fake_pid_file = nil   # nil = unreadable; a String is the file's contents
$fake_pgrep    = ""    # what pgrep writes to stdout

# Shimmed for the one path the guard reads, so any other File call still behaves. The
# original File.read is kept because this script needs it to read the cask itself.
class << File
  alias_method :orig_readable?, :readable?
  alias_method :orig_read, :read

  def readable?(path)
    path == PID_FILE ? !$fake_pid_file.nil? : orig_readable?(path)
  end

  def read(path, *args)
    path == PID_FILE ? $fake_pid_file : orig_read(path, *args)
  end
end

Result = Struct.new(:stdout)

# Stands in for Cask::DSL::Base. The assertions are deliberate: a guard that demanded
# success from pgrep would abort on the ordinary "no match" exit of 1, and one that
# printed its output would spill pids into brew's console. Both have to stay wrong.
class DSLShim
  def system_command(_executable, args:, must_succeed:, print_stdout:)
    raise "guard must not require pgrep to succeed — exit 1 is its no-match case" if must_succeed
    raise "guard must not print pgrep output" if print_stdout
    raise "unexpected pgrep args: #{args.inspect}" unless args == ["-f", "--", "--pid-file=#{PID_FILE}"]

    Result.new($fake_pgrep)
  end
end

cask_path = ARGV[0] or abort "usage: cask-guard-harness.rb <rendered-cask.rb>"
lines = File.orig_read(cask_path).lines

start = lines.index { |l| l.start_with?("  uninstall_preflight do") }
abort "FAIL: no uninstall_preflight stanza in #{cask_path} — the guard is missing" unless start
stop = (start + 1...lines.length).find { |i| lines[i] == "  end\n" }
abort "FAIL: unterminated uninstall_preflight block" unless stop
body = lines[(start + 1)...stop].join

def attempt(body)
  DSLShim.new.instance_eval(body)
  :allowed
rescue Cask::CaskError => e
  [:refused, e.message]
end

# A live process of our own, a live root-owned one, and a reaped one.
mine = spawn("/bin/sleep", "120")
root = `ps -axo pid=,user= | awk '$2=="root" && $1>1 {print $1; exit}'`.strip.to_i
reaped = spawn("/usr/bin/true")
Process.wait(reaped)
abort "FAIL: could not find a live root process to test the EPERM path" if root.zero?

passed = 0
failed = 0

expect = lambda do |name, want|
  got = attempt(body)
  verdict = got.is_a?(Array) ? got.first : got
  if verdict == want
    passed += 1
  else
    failed += 1
    puts "FAIL: #{name} -> #{verdict}, wanted #{want}"
    puts got.last.lines.map { |l| "        #{l}" }.join if got.is_a?(Array)
  end
end

ENV.delete("ANYWAY_CONNECT_ALLOW_LIVE_TEARDOWN")

# Nothing to protect: the guard must stay out of the way. A guard that refuses when no
# tunnel exists would make every uninstall need the escape hatch, and the hatch would
# become the habit.
$fake_pid_file = nil
$fake_pgrep = ""
expect.call("no pid file and no openconnect", :allowed)

$fake_pid_file = "#{reaped}\n"
expect.call("pid file naming a process that has exited", :allowed)

$fake_pid_file = "1\n"
expect.call("pid file naming pid 1", :allowed)

# kill(0, 0) signals the caller's whole process group, so 0 must never be probed. The
# daemon has the same rule for the same reason; NetReconcile.swift spells it out.
$fake_pid_file = "0\n"
expect.call("pid file naming pid 0", :allowed)

$fake_pid_file = "not a number\n"
expect.call("unparseable pid file", :allowed)

$fake_pid_file = nil
$fake_pgrep = "#{reaped}\n"
expect.call("pgrep naming a process that has since exited", :allowed)

# A tunnel is up: the guard must refuse, whichever source saw it.
$fake_pid_file = "#{mine}\n"
$fake_pgrep = ""
expect.call("pid file naming a live process", :refused)

# The one that matters. openconnect runs as root, so kill(0) from this user fails with
# EPERM — and reading that as "gone" would let the uninstall delete route-wrapper.sh out
# from under a live tunnel, which is the whole failure this guard exists to prevent.
$fake_pid_file = "#{root}\n"
$fake_pgrep = ""
expect.call("pid file naming a live ROOT process (EPERM means alive)", :refused)

$fake_pid_file = nil
$fake_pgrep = "#{mine}\n"
expect.call("no pid file but pgrep finds a live openconnect", :refused)

$fake_pid_file = "#{mine}\n"
$fake_pgrep = "#{mine}\n"
expect.call("the same pid from both sources", :refused)

$fake_pid_file = "#{reaped}\n"
$fake_pgrep = "#{root}\n"
expect.call("dead pid file alongside a live pgrep hit", :refused)

# The escape hatch has to work, or a stale pid file wedges uninstalling for good.
ENV["ANYWAY_CONNECT_ALLOW_LIVE_TEARDOWN"] = "1"
$fake_pid_file = "#{mine}\n"
$fake_pgrep = ""
expect.call("live tunnel with the escape hatch set", :allowed)
ENV.delete("ANYWAY_CONNECT_ALLOW_LIVE_TEARDOWN")

# A refusal nobody can act on is a dead end, so the message is part of the contract.
$fake_pid_file = "#{mine}\n"
$fake_pgrep = ""
message = attempt(body).last.to_s
{
  "the live pid"            => mine.to_s,
  "what to do"              => "disconnect",
  "the escape hatch"        => "ANYWAY_CONNECT_ALLOW_LIVE_TEARDOWN",
  "what would be destroyed" => "/usr/local/libexec/anyway-connect",
}.each do |description, needle|
  if message.downcase.include?(needle.downcase)
    passed += 1
  else
    failed += 1
    puts "FAIL: the refusal does not name #{description} (#{needle})"
  end
end

Process.kill("TERM", mine)
Process.wait(mine)

puts "#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
