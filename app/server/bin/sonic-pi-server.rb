#!/usr/bin/env ruby
#--
# This file is part of Sonic Pi: http://sonic-pi.net
# Full project source: https://github.com/samaaron/sonic-pi
# License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
#
# Copyright 2013, 2014, 2015, 2016 by Sam Aaron (http://sam.aaron.name).
# All rights reserved.
#
# Permission is granted for use, copying, modification, and
# distribution of modified versions of this work as long as this
# notice is included.
#++

require 'cgi'
require 'rbconfig'


require_relative "../core.rb"
require_relative "../sonicpi/lib/sonicpi/studio"

require_relative "../sonicpi/lib/sonicpi/server"
require_relative "../sonicpi/lib/sonicpi/util"
require_relative "../sonicpi/lib/sonicpi/osc/osc"
require_relative "../sonicpi/lib/sonicpi/lang/core"
require_relative "../sonicpi/lib/sonicpi/lang/minecraftpi"
require_relative "../sonicpi/lib/sonicpi/lang/midi"
require_relative "../sonicpi/lib/sonicpi/lang/sound"
#require_relative "../sonicpi/lib/sonicpi/lang/pattern"
require_relative "../sonicpi/lib/sonicpi/runtime"
require "/Users/josephwilk/Workspace/repl-electric/live-coding-space/lib/midi.rb"

require 'multi_json'
require 'memoist'

STDOUT.puts "Sonic Pi server booting..."

include SonicPi::Util

protocol = case ARGV[0]
           when "-t"
             :tcp
           else
             :udp
           end
STDOUT.puts "Using protocol: #{protocol}"
STDOUT.puts "Detecting port numbers..."

server_port = ARGV[1] ? ARGV[1].to_i : 4557
client_port = ARGV[2] ? ARGV[2].to_i : 4558
scsynth_port = ARGV[3] ? ARGV[3].to_i : 4556
scsynth_send_port = ARGV[4] ? ARGV[4].to_i : 4556
osc_cues_port = ARGV[5] ? ARGV[5].to_i : 4559
erlang_port = ARGV[6] ? ARGV[6].to_i : 4560
osc_midi_out_port = ARGV[7] ? ARGV[7].to_i : 4561
osc_midi_in_port = ARGV[8] ? ARGV[8].to_i : 4562

check_port = lambda do |port, gui|
  begin
    s = SonicPi::OSC::UDPServer.new(port)
    s.stop
    STDOUT.puts "  - OK"
  rescue Exception => e
    begin
      STDOUT.puts "Port #{port} unavailable. Perhaps Sonic Pi is already running?"
      STDOUT.flush
      gui.send("/exited-with-boot-error", "Port unavailable: " + port.to_s + ", is scsynth already running?")
    rescue Errno::EPIPE => e
      STDOUT.puts "GUI not listening, exit anyway."
    end
    exit
  end
end


STDOUT.puts "Send port: #{client_port}"

begin
  if protocol == :tcp
    gui = SonicPi::OSC::TCPClient.new("127.0.0.1", client_port, use_encoder_cache: true)
  else
    gui = SonicPi::OSC::UDPClient.new("127.0.0.1", client_port, use_encoder_cache: true)
  end
rescue Exception => e
  STDOUT.puts "Exception when opening socket to talk to GUI!"
  STDOUT.puts e.message
  STDOUT.puts e.backtrace.inspect
  STDOUT.puts e.backtrace
end


STDOUT.puts "Listen port: #{server_port}"
check_port.call(server_port, gui)
STDOUT.puts "Scsynth port: #{scsynth_port}"
check_port.call(scsynth_port, gui)
STDOUT.puts "Scsynth send port: #{scsynth_send_port}"
check_port.call(scsynth_send_port, gui)
STDOUT.puts "OSC cues port: #{osc_cues_port}"
check_port.call(osc_cues_port, gui)
STDOUT.puts "Erlang port: #{erlang_port}"
check_port.call(erlang_port, gui)
STDOUT.puts "OSC MIDI out port: #{osc_midi_out_port}"
check_port.call(osc_midi_out_port, gui)
STDOUT.puts "OSC MIDI in port: #{osc_midi_in_port}"
check_port.call(osc_midi_in_port, gui)

STDOUT.flush

sonic_pi_ports = {
  server_port: server_port,
  scsynth_port: scsynth_port,
  scsynth_send_port: scsynth_send_port,
  osc_cues_port: osc_cues_port,
  erlang_port: erlang_port,
  osc_midi_out_port: osc_midi_out_port,
  osc_midi_in_port: osc_midi_in_port }.freeze


begin
  if protocol == :tcp
    osc_server = SonicPi::OSC::TCPServer.new(server_port, use_decoder_cache: true)
  else
    osc_server = SonicPi::OSC::UDPServer.new(server_port, use_decoder_cache: true)
  end
rescue Exception => e
  begin
    STDOUT.puts "Exception when opening a socket to listen from GUI!"
    STDOUT.puts e.message
    STDOUT.puts e.backtrace.inspect
    STDOUT.puts e.backtrace
    gui.send("/exited-with-boot-error", "Failed to open server port " + server_port.to_s + ", is scsynth already running?")
  rescue Errno::EPIPE => e
    STDOUT.puts "GUI not listening, exit anyway."
  end
  exit
end


at_exit do
  STDOUT.puts "                      "
  begin
  STDOUT.puts "                      "
  STDOUT.puts "                 \\:o/     π=-      π=-"
  STDOUT.puts "                  █         π=-   π   π=-   π=-"
  STDOUT.puts "                 .||.      π=-  π=-  π=-"

  STDOUT.puts "        "

  STDOUT.puts "                   :o       ███████  "
  STDOUT.puts "                  [█]       ███████ "
  STDOUT.puts "                 .||.       ███████"

  gui.send("/exited")
  rescue Errno::EPIPE => e
    STDOUT.puts "GUI not listening."
  end
  STDOUT.puts "        "
  STDOUT.puts "                  \\:D"
  STDOUT.puts "                   █\\"
  STDOUT.puts "                   |\\"
  STDOUT.puts "        "
  STDOUT.puts "                      "
  STDOUT.puts "                 d[-_-]b     "
  STDOUT.puts "                   /█\\      "
  STDOUT.puts "                   .Π.       "
  STDOUT.puts "                             "
end

user_methods = Module.new
name = "SonicPiLang" # this should be autogenerated
klass = Object.const_set name, Class.new(SonicPi::Runtime)

klass.send(:include, user_methods)
klass.send(:include, SonicPi::Lang::Core)
klass.send(:include, SonicPi::Lang::Sound)
klass.send(:include, SonicPi::Lang::Minecraft)
klass.send(:include, SonicPi::Lang::Midi)
klass.send(:include, SonicPi::Lang::Support::DocSystem)
klass.send(:include, ReplElectric::Midi)
klass.send(:extend, Memoist)

# This will pick up all memoizable fns in all modules as they share the
# same docsystem.
# TODO think of a better way to modularise this stuff when we move to
# using namespaces...

SonicPi::Lang::Core.memoizable_fns.each do |f|
  klass.send(:memoize, f)
end


klass.send(:define_method, :inspect) { "Runtime" }
#klass.send(:include, SonicPi::Lang::Pattern)

ws_out = Queue.new

begin
  sp =  klass.new sonic_pi_ports, ws_out, user_methods

  # read in init.rb if exists
  if File.exists?(init_path)
    sp.__spider_eval(File.read(init_path), {silent: false, workspace: init_path})
  else
    begin
    File.open(init_path, "w") do |f|
      f.puts "# Sonic Pi init file"
      f.puts "# Code in here will be evaluated on launch."
      f.puts ""
      end
    rescue
      log "Warning: unable to create init file at #{init_path}"
    end
  end

  sp.__print_boot_messages

rescue Exception => e
  STDOUT.puts "Failed to start server: " + e.message
  STDOUT.puts e.backtrace.join("\n")
  gui.send("/exited-with-boot-error", "Server Exception:\n #{e.message}\n #{e.backtrace}")
  exit
end

osc_server.add_method("/run-code") do |args|
  gui_id = args[0]
  code = args[1].force_encoding("utf-8")
  sp.__spider_eval code
end

REPL_ELECTRIC_SETUP = "use_cue_logging false #__nosave__\n" +
    "use_debug false  #__nosave__\n" +
    "use_midi_defaults port: :iac_bus_1, channel: 1 #__nosave__\n" +
  #  + "♥️=Straw  #__nosave__\n"+
#    + "🌶️=Straw #__nosave__\n" +
#    "☠️=@slices #__nosave__\n" +
    "@points ||= 0 #__nosave__\n" +
    "@mode ||= \"points\" #__nosave__\n" +
    "@osc_server ||=  SonicPi::OSC::UDPServer.new(4559, use_decoder_cache: true) #__nosave__" +
    "D4=:d4;E4=:e4;FS4=:Fs4;GS4=:Gs4;Cs4=:Cs4;A4=:A4;B4=:B4;D3=:d3;E3=:e3;FS3=:Fs3;GS3=:Gs3;Cs3=:Cs3;A3=:A3;B3=:B3;D2=:d2;E2=:e2;FS2=:Fs2;GS2=:Gs2;Cs2=:Cs2;A2=:A2;B2=:B2;C2=:c2;C3=:c3 #__nonsave__" +
    "(MAX_POINTS = 100000) unless defined?(MAX_POINTS) #__nosave__\n"

osc_server.add_method("/save-and-run-buffer-via-local-file") do |args|
  gui_id = args[0]
  buffer_id = args[1]
  path = args[2].force_encoding("utf-8")
  code = REPL_ELECTRIC_SETUP + File.read(File.expand_path(path.to_s))
  workspace = args[3]
  sp.__save_buffer(buffer_id, code)
  sp.__spider_eval code, {workspace: workspace}
end

osc_server.add_method("/save-and-run-buffer") do |args|
  gui_id = args[0]
  buffer_id = args[1]
  code = args[2].force_encoding("utf-8")
  workspace = args[3]
  sp.__save_buffer(buffer_id, code)
  sp.__spider_eval code, {workspace: workspace}
end

osc_server.add_method("/save-buffer") do |args|
  gui_id = args[0]
  buffer_id = args[1]
  code = args[2].force_encoding("utf-8")
  sp.__save_buffer(buffer_id, code)
end

osc_server.add_method("/exit") do |args|
  gui_id = args[0]
  sp.__exit
end

osc_server.add_method("/stop-all-jobs") do |args|
  gui_id = args[0]
  sp.__stop_jobs
  #Stop all external synths.
  sp.__spider_eval("midi_cc(0, channel: 16, port: 'iac_bus_1')", {workspace: "FAKE"})
end

osc_server.add_method("/load-buffer") do |args|
  gui_id = args[0]
  sp.__load_buffer args[1]
end

osc_server.add_method("/buffer-newline-and-indent") do |args|
  gui_id = args[0]
  id = args[1]
  buf = args[2].force_encoding("utf-8")
  point_line = args[3]
  point_index = args[4]
  first_line = args[5]
  sp.__buffer_newline_and_indent(id, buf, point_line, point_index, first_line)
end

osc_server.add_method("/buffer-section-complete-snippet-or-indent-selection") do |args|
  gui_id = args[0]
  id = args[1]
  buf = args[2].force_encoding("utf-8")
  start_line = args[3]
  finish_line = args[4]
  point_line = args[5]
  point_index = args[6]
  sp.__buffer_complete_snippet_or_indent_lines(id, buf, start_line, finish_line, point_line, point_index)
end

osc_server.add_method("/buffer-indent-selection") do |args|
  gui_id = args[0]
  id = args[1]
  buf = args[2].force_encoding("utf-8")
  start_line = args[3]
  finish_line = args[4]
  point_line = args[5]
  point_index = args[6]
  sp.__buffer_indent_lines(id, buf, start_line, finish_line, point_line, point_index)
end

osc_server.add_method("/buffer-section-toggle-comment") do |args|
  gui_id = args[0]
  id = args[1]
  buf = args[2].force_encoding("utf-8")
  start_line = args[3]
  finish_line = args[4]
  point_line = args[5]
  point_index = args[6]
  sp.__toggle_comment(id, buf, start_line, finish_line, point_line, point_index)
end

osc_server.add_method("/buffer-beautify") do |args|
  gui_id = args[0]
  id = args[1]
  buf = args[2].force_encoding("utf-8")
  line = args[3]
  index = args[4]
  first_line = args[5]
  sp.__buffer_beautify(id, buf, line, index, first_line)
end

osc_server.add_method("/ping") do |args|
  gui_id = args[0]
  id = args[1]
  gui.send("/ack", id)
end

osc_server.add_method("/start-recording") do |args|
  gui_id = args[0]
  sp.recording_start
end

osc_server.add_method("/stop-recording") do |args|
  gui_id = args[0]
  sp.recording_stop
end

osc_server.add_method("/delete-recording") do |args|
  gui_id = args[0]
  sp.recording_delete
end

osc_server.add_method("/save-recording") do |args|
  gui_id = args[0]
  filename = args[1]
  sp.recording_save(filename)
end

osc_server.add_method("/reload") do |args|
  gui_id = args[0]
  dir = File.dirname("#{File.absolute_path(__FILE__)}")
  Dir["#{dir}/../sonicpi/**/*.rb"].each do |d|
    load d
  end
  puts "reloaded"
end

osc_server.add_method("/mixer-invert-stereo") do |args|
  gui_id = args[0]
  sp.set_mixer_invert_stereo!
end

osc_server.add_method("/mixer-standard-stereo") do |args|
  gui_id = args[0]
  sp.set_mixer_standard_stereo!
end

osc_server.add_method("/mixer-stereo-mode") do |args|
  gui_id = args[0]
  sp.set_mixer_stereo_mode!
end

osc_server.add_method("/mixer-mono-mode") do |args|
  gui_id = args[0]
  sp.set_mixer_mono_mode!
end

osc_server.add_method("/mixer-hpf-enable") do |args|
  gui_id = args[0]
  freq = args[1].to_f
  sp.set_mixer_hpf!(freq)
end

osc_server.add_method("/mixer-hpf-disable") do |args|
  gui_id = args[0]
  sp.set_mixer_hpf_disable!
end

osc_server.add_method("/mixer-lpf-enable") do |args|
  gui_id = args[0]
  freq = args[1].to_f
  sp.set_mixer_lpf!(freq)
end

osc_server.add_method("/mixer-lpf-disable") do |args|
  gui_id = args[0]
  sp.set_mixer_lpf_disable!
end

osc_server.add_method("/mixer-amp") do |args|
  gui_id = args[0]
  amp = args[1]
  silent = args[2] == 1
  sp.set_volume!(amp, true, silent)
end

osc_server.add_method("/enable-update-checking") do |args|
  gui_id = args[0]
  sp.__enable_update_checker
end

osc_server.add_method("/disable-update-checking") do |args|
  gui_id = args[0]
  sp.__disable_update_checker
end

osc_server.add_method("/check-for-updates-now") do |args|
  gui_id = args[0]
  sp.__update_gui_version_info_now
end

osc_server.add_method("/version") do |args|
  gui_id = args[0]
  v = sp.__current_version
  lv = sp.__server_version
  lc = sp.__last_update_check
  plat = host_platform_desc
  gui.send("/version", v.to_s, v.to_i, lv.to_s, lv.to_i, lc.day, lc.month, lc.year, plat.to_s)
end

osc_server.add_method("/gui-heartbeat") do |args|
  gui_id = args[0]
  sp.__gui_heartbeat gui_id
end

osc_server.add_method("/midi-start") do |args|
  gui_id = args[0]
  silent = args[1] == 1
  sp.__midi_system_start(silent)
end

osc_server.add_method("/midi-stop") do |args|
  gui_id = args[0]
  silent = args[1] == 1
  sp.__midi_system_stop(silent)
end

osc_server.add_method("/midi-reset") do |args|
  gui_id = args[0]
  silent = args[1] == 1
  sp.__midi_system_reset(silent)
end

osc_server.add_method("/osc-port-start") do |args|
  gui_id = args[0]
  silent = args[1] == 1
  open = args[2] == 1
  sp.__restart_cue_server!(open, silent)
end

osc_server.add_method("/osc-port-stop") do |args|
  gui_id = args[0]
  silent = args[1] == 1
  sp.__stop_cue_server!(silent)
end

# Send stuff out from Sonic Pi back out to osc_server
out_t = Thread.new do
  continue = true
  while continue
    begin
      message = ws_out.pop
      # message[:ts] = Time.now.strftime("%H:%M:%S")

      if message[:type] == :exit
        begin
          gui.send("/exited")
        rescue Errno::EPIPE => e
          STDOUT.puts "GUI not listening, exit anyway."
        end
        continue = false
      else
        case message[:type]
        when :incoming
          gui.send("/incoming/osc", message[:time], message[:id], message[:address], message[:args])
        when :multi_message
          gui.send("/log/multi_message", message[:jobid], message[:thread_name].to_s, message[:runtime].to_s, message[:val].size, *message[:val].flatten)
        when :midi_out_ports
          gui.send("/midi/out-ports", message[:val])
        when :midi_in_ports
          gui.send("/midi/in-ports", message[:val])
        when :info
          gui.send("/log/info", message[:style] || 0, message[:val] || "")
        when :syntax_error
          desc = message[:val] || ""
          line = message[:line] || -1
          error_line = message[:error_line] || ""
          desc = CGI.escapeHTML(desc)
          gui.send("/syntax_error", message[:jobid], desc, error_line, line, line.to_s)
        when :error
          desc = message[:val] || ""
          trace = message[:backtrace].join("\n")
          line = message[:line] || -1
          # TODO: Move this escaping to the Qt Client
          desc = CGI.escapeHTML(desc)
          trace = CGI.escapeHTML(trace)
          # puts "sending: /error #{desc}, #{trace}"
          gui.send("/error", message[:jobid], desc, trace, line)
        when "replace-buffer"
          buf_id = message[:buffer_id]
          content = message[:val] || "Internal error within a fn calling replace-buffer without a :val payload"
          line = message[:line] || 0
          index = message[:index] || 0
          first_line = message[:first_line] || 0
          #          puts "replacing buffer #{buf_id}, #{content}"
          gui.send("/buffer/replace", buf_id, content, line, index, first_line)
        when "replace-buffer-idx"
          buf_idx = message[:buffer_idx] || 0
          content = message[:val] || "Internal error within a fn calling replace-buffer-idx without a :val payload"
          line = message[:line] || 0
          index = message[:index] || 0
          first_line = message[:first_line] || 0
          #          puts "replacing buffer #{buf_id}, #{content}"
          gui.send("/buffer/replace-idx", buf_idx, content, line, index, first_line)
        when "run-buffer-idx"
          buf_idx = message[:buffer_idx] || 0
          #          puts "running buffer #{buf_idx}"
          gui.send("/buffer/run-idx", buf_idx)
        when "replace-lines"
          buf_id = message[:buffer_id]
          content = message[:val] || "Internal error within a fn calling replace-line without a :val payload"
          point_line = message[:point_line] || 0
          point_index = message[:point_index] || 0
          start_line = message[:start_line] || point_line
          finish_line = message[:finish_line] || start_line
          #          puts "replacing line #{buf_id}, #{content}"
          gui.send("/buffer/replace-lines", buf_id, content, start_line, finish_line, point_line, point_index)
        when :version
          v = message[:version]
          v_num = message[:version_num]
          lv = message[:latest_version]
          lv_num = message[:latest_version_num]
          lc = message[:last_checked]
          plat = host_platform_desc
          gui.send("/version", v.to_s, v_num.to_i, lv.to_s, lv_num.to_i, lc.day, lc.month, lc.year, plat.to_s)
        when :all_jobs_completed
          gui.send("/runs/all-completed")
        when :job
          id = message[:job_id]
          action = message[:action]
          # do nothing for now
        else
          STDOUT.puts "ignoring #{message}"
        end

      end
    rescue Exception => e
      STDOUT.puts "Exception!"
      STDOUT.puts e.message
      STDOUT.puts e.backtrace.inspect
    end
  end
end

puts "This is Sonic Pi #{sp.__current_version} running on #{os} with ruby api #{RbConfig::CONFIG['ruby_version']}."
puts "Sonic Pi Server successfully booted."

STDOUT.flush

out_t.join
