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
require 'tmpdir'
require 'fileutils'
require 'thread'
require 'net/http'
require "hamster/set"
require "hamster/hash"
require_relative "../blanknode"
require_relative "../chainnode"
require_relative "../fxnode"
require_relative "../fxreplacenode"
require_relative "../lazynode"
require_relative "../note"
require_relative "../scale"
require_relative "../chord"
require_relative "../chordgroup"
require_relative "../synthtracker"
require_relative "../version"
require_relative "../tuning"
require_relative "../sample_loader"
require_relative "support/docsystem"

class Symbol
  def -(other)
    return self if (self == :r) || (self == :rest)
    SonicPi::Note.resolve_midi_note_without_octave(self) - SonicPi::Note.resolve_midi_note_without_octave(other)
  end

  def +(other)
    return self if (self == :r) || (self == :rest)
    SonicPi::Note.resolve_midi_note_without_octave(self) + SonicPi::Note.resolve_midi_note_without_octave(other)
  end

  def to_f
    return 0.0 if (self == :r) || (self == :rest)
    SonicPi::Note.resolve_midi_note_without_octave(self).to_f
  end

  def to_i
    self.to_f.to_i
  end
end

class NilClass
  def -(other)
    return nil
  end

  def +(other)
    return nil
  end
end

module SonicPi
  module Lang
    module Sound

      class BufferLookup
        def initialize(blk)
          @blk = blk
        end

        def [](*args)
          @blk.call(*args)
        end
      end

      include SonicPi::Util
      include SonicPi::Lang::Support::DocSystem

      DEFAULT_PLAY_OPTS = {
        amp:           "The amplitude of the note",
        amp_slide:     "The duration in beats for amplitude changes to take place",
        pan:           "The stereo position of the sound. -1 is left, 0 is in the middle and 1 is on the right. You may use a value in between -1 and 1 such as 0.25",
        pan_slide:     "The duration in beats for the pan value to change",
        attack:        "Amount of time (in beats) for sound to reach full amplitude (attack_level). A short attack (i.e. 0.01) makes the initial part of the sound very percussive like a sharp tap. A longer attack (i.e 1) fades the sound in gently.",
        decay:         "Amount of time (in beats) for the sound to move from full amplitude (attack_level) to the sustain amplitude (sustain_level).",
        sustain:       "Amount of time (in beats) for sound to remain at sustain level amplitude. Longer sustain values result in longer sounds. Full length of sound is attack + decay + sustain + release.",
        release:       "Amount of time (in beats) for sound to move from sustain level amplitude to silent. A short release (i.e. 0.01) makes the final part of the sound very percussive (potentially resulting in a click). A longer release (i.e 1) fades the sound out gently.",
        attack_level:  "Amplitude level reached after attack phase and immediately before decay phase",
        decay_level:   "Amplitude level reached after decay phase and immediately before sustain phase. Defaults to sustain_level unless explicitly set",
        sustain_level: "Amplitude level reached after decay phase and immediately before release phase.",
        env_curve:     "Select the shape of the curve between levels in the envelope. 1=linear, 2=exponential, 3=sine, 4=welch, 6=squared, 7=cubed",
        slide:         "Default slide time in beats for all slide opts. Individually specified slide opts will override this value",
        pitch:         "Pitch adjustment in semitones. 1 is up a semitone, 12 is up an octave, -12 is down an octave etc.  Decimal numbers can be used for fine tuning.",
        on:            "If specified and false/nil/0 will stop the synth from being played. Ensures all opts are evaluated."}



      def self.included(base)
        base.instance_exec {alias_method :sonic_pi_mods_sound_initialize_old, :initialize}

        base.instance_exec do
          define_method(:initialize) do |*splat, &block|
            sonic_pi_mods_sound_initialize_old(*splat, &block)
            ports, msg_queue = *splat

            @server_init_args = splat.take(4)
            @mod_sound_home_dir = Dir.home
            @simple_sampler_args = [:amp, :amp_slide, :amp_slide_shape, :amp_slide_curve, :pan, :pan_slide, :pan_slide_shape, :pan_slide_curve, :cutoff, :cutoff_slide, :cutoff_slide_shape, :cutoff_slide_curve, :lpf, :lpf_slide, :lpf_slide_shape, :lpf_slide_curve, :hpf, :hpf_slide, :hpf_slide_shape, :hpf_slide_curve, :rate, :slide, :beat_stretch, :rpitch, :attack, :decay, :sustain, :release, :attack_level, :decay_level, :sustain_level, :env_curve]

            init_tuning

            @sample_paths_cache = {}

            @sample_loader = SampleLoader.new("#{samples_path}/**")

            @JOB_GROUPS_A = Atom.new(Hamster::Hash.new)
            @JOB_GROUP_MUTEX = Mutex.new
            @JOB_MIXERS_A = Atom.new(Hamster::Hash.new)
            @JOB_MIXERS_MUTEX = Mutex.new
            @JOB_BUSSES_A = Atom.new(Hamster::Hash.new)
            @JOB_BUSSES_MUTEX = Mutex.new
            @mod_sound_studio = Studio.new(ports, msg_queue, @system_state, @register_cue_event_lambda)

            buf_lookup = lambda do |name, duration=nil|
              # scale duration to the current BPM
              duration ||= 8
              duration = duration * __system_thread_locals.get(:sonic_pi_spider_sleep_mul, 1)
              name = name.to_sym

              buf, cached = @mod_sound_studio.allocate_buffer(name, duration)
              __info "Initialised buffer #{name.inspect}, #{duration}s" unless cached
              buf
            end

            @buffer_lookup_w_hash_syntax = BufferLookup.new(buf_lookup)

            @mod_sound_studio_checker = Thread.new do
              # kill all jobs if an error occured in the studio
              __system_thread_locals.set_local(:sonic_pi_local_thread_group, :studio_checker)
              Thread.current.priority = 200
              Kernel.loop do
                Kernel.sleep 5
                begin
                  error = @mod_sound_studio.error_occurred?
                  if error
                    __stop_jobs
                  end
                rescue Exception => e
                  __info "exception: #{e.message}, #{e.backtrace}"
                  __stop_jobs
                end
              end
            end

            @life_hooks.on_init do |job_id, payload|
              # Do nothing for now
              @mod_sound_studio.start
            end

            @life_hooks.on_killed do |job_id, payload|
              # Do nothing for now
            end

            @life_hooks.on_completed do |job_id, payload|
              # Do nothing for now
            end

            @life_hooks.on_all_completed do |silent=false|
              @mod_sound_studio.pause(silent)
            end

            @life_hooks.on_exit do |job_id, payload|
              __system_thread_locals.set(:sonic_pi_spider_start_time, payload[:start_t])
              __system_thread_locals.set_local(:sonic_pi_local_thread_group, "job_remover-#{job_id}".freeze)
              Thread.current.priority = -10
              shutdown_job_mixer(job_id)
              kill_job_group(job_id)
              free_job_bus(job_id)
            end

            @cue_events.add_handler("/exit", @cue_events.gensym("/mods-sound-exit")) do |payload|
              @mod_sound_studio.shutdown
              nil
            end
          end
        end
      end

      def live_audio(*params)
        args, opts = split_params_and_merge_opts_array(params)

        synth_name = if truthy?(opts[:stereo])
                       "sonic-pi-live_audio_stereo"
                     else
                       "sonic-pi-live_audio_mono"
                     end
        opts.delete(:stereo)
        raise "live_audio requires a name" if args.empty?
        id = args[0]
        sn_sym = synth_name.to_sym
        info = Synths::SynthInfo.get_info(sn_sym)
        synth_name = info ? info.scsynth_name : synth_name

        if args.size > 1 && ((args[1] == nil) || (args[1] == :stop))
          # kill synth
          return @mod_sound_studio.kill_live_synth(id)
        end

        unless __thread_locals.get(:sonic_pi_mod_sound_synth_silent)
          __delayed_message "live_audio #{id.inspect}, #{arg_h_pp(opts)}"
        end

        trigger_live_synth(synth_name, opts, current_group, info, false, current_out_bus, false, :tail, id)
      end
      doc name:           :live_audio,
          introduced:     Version.new(3,0,0),
          summary:        "A named audio stream live from your soundcard",
          args:           [[]],
          returns:        :SynthNode,
          #   opts:           {sound_in_stereo: {doc: "",
          #   default: true
          # }},
          accepts_block:  false,
          args_size:      0,
          opts_keys:      [:sound_in_stereo],
          doc:            "Create a named synthesiser which works similar to `play`, `sample` or `synth`. Rather than synthesising the sound mathematically or playing back recorded audio, it streams audio live from your sound card.

However, unlike `play`, `sample` and `synth`, which allow multiple similar synths to play at the same time (i.e. a chord) only one `live_audio` synth of a given name may exist in the system at any one time. This is similar to `live_loop` where only one live loop of each name may exist at any one time. See examples for further information.

An additional difference is that `live_audio` will create an infinitely long synth rather than be timed to an envelope like the standard `synth` and `sample` synths. This is particularly suitable for working with continuous incoming audio streams where the source of the audio is unknown (for example, it may be a guitar, an analog synth or an electronic violin). If the source is continuous, then it may not be suited to being stitched together by successive enveloped calls to something like: `synth :sound_in, attack: 0, sustain: 4, release: 0`. If we were to `live_loop` this with a `sleep 4` to match the sustain duration, we would get something that emulated a continuous stream, but for certain inputs you'll hear clicking at the seams between each successive call to `synth` where the final part of the audio signal from the previous synth doesn't precisely match up with the start of the signal in the next synth due to very minor timing differences.

Another important feature of `live_audio` is that it will automatically move an existing `live_audio` synth into the current FX context. This means you can live code the FX chain around the live stream and it will update automatically. See examples.

To stop a `live_audio` synth, use the `:stop` arg: `live_audio :foo, :stop`.
.
",
      examples:       ["
# Basic usage
live_audio :foo  # Play whatever audio is coming into the sound card on input 1
",
        "
# Specify an input
live_audio :foo, input: 3  # Play whatever audio is coming into the sound card on input 3
",
        "
# Work with stereo input
live_audio :foo, input: 3, stereo: true  # Play whatever audio is coming into the sound card on inputs 3 and 4
                                         # as a stereo stream
",


        "# Switching audio contexts (i.e. changing FX)
live_audio :guitar     # Play whatever audio is coming into the sound card on input 1

sleep 2                # Wait for 2 seconds then...

with_fx :reverb do
  live_audio :guitar   # Add reverb to the audio from input 1
end

sleep 2                # Wait for another 2 seconds then...

live_audio :guitar     # Remove the reverb from input 1
",
        "
# Working with live_loops

live_loop :foo do
  with_fx [:reverb, :distortion, :echo].choose do   # chooses a new FX each time round the live loop
    live_audio :voice                               # the audio stream from input 1 will be moved to the
  end                                               # new FX and the old FX will complete and finish as normal.
  sleep 8
end",
        "
# Stopping

live_audio :foo            #=> start playing audio from input 1
live_audio :bar, input: 2  #=> start playing audio from input 2

sleep 3                    #=> wait for 3s...

live_audio :foo, :stop     #=> stop playing audio from input 1
                           #=> (live_audio :bar is still playing)
"
]


      # def opts
      #   __thread_locals.get(:sonic_pi_mod_sound_defn_args_opts, [[], {}])[1]
      # end

      # def args
      #   __thread_locals.get(:sonic_pi_mod_sound_defn_args_opts, [[], {}])[0]
      # end


      # Deprecated fns

      def current_sample_pack_aliases(*args)
        raise "Sorry, current_sample_pack_aliases is no longer supported since v2.10. Please read Section 3.7 of the tutorial for a more powerful replacement."
      end

      def with_sample_pack_as(*args)
        raise "Sorry, with_sample_pack_as is no longer supported since v2.10. Please read Section 3.7 of the tutorial for a more powerful replacement."
      end

      def use_sample_pack_as(*args)
        raise "Sorry, use_sample_pack_as is no longer supported since v2.10. Please read Section 3.7 of the tutorial for a more powerful replacement."
      end

      def use_sample_pack(pack, &block)
        raise "Sorry, use_sample_pack is no longer supported since v2.11. \n  Please read Section 3.7 of the tutorial for a more powerful replacement."
      end

      def with_sample_pack(pack, &block)
        raise "Sorry, with_sample_pack is no longer supported since v2.11. \n  Please read Section 3.7 of the tutorial for a more powerful replacement."
      end
      # End deprecated methods

      def reboot

        if @mod_sound_studio.rebooting
          __info "Already rebooting sound server"
          return nil
        end
        @sample_loader.reset!
        __no_kill_block do
          __stop_other_jobs

          res = @mod_sound_studio.reboot

          if res
            __info "Reboot successful - sound server ready."
          else
            __info "Reboot unsuccessful - reboot already in progress."
          end
        end
        stop
      end


      def scsynth_info
        @mod_sound_studio.scsynth_info
      end
      doc name:           :scsynth_info,
          introduced:     Version.new(2,11,0),
          summary:        "Return information about the internal SuperCollider sound server",
          args:           [[]],
          returns:        :SPMap,
          opts:           nil,
          accepts_block:  false,
          doc:            "Create a map of information about the running audio synthesiser SuperCollider. ",
          examples:       [
        "puts scsynth_info  #=>  (map sample_rate: 44100.0,
                            #         sample_dur: 2.2675736545352265e-05,
                            #         radians_per_sample: 0.00014247585204429924,
                            #         control_rate: 689.0625,
                            #         control_dur: 0.001451247138902545,
                            #         subsample_offset: 0.0,
                            #         num_output_busses: 16.0,
                            #         num_input_busses: 16.0,
                            #         num_audio_busses: 1024.0,
                            #         num_control_busses: 4096.0,
                            #         num_buffers: 4096.0)",
]

      def octs(start, num_octs=1)
        a = []
        num_octs.times do |i|
          a << (note(start) + (12 * i))
        end
        a.ring
      end
      doc name:           :octs,
          introduced:     Version.new(2,8,0),
          summary:        "Create a ring of octaves",
          args:           [[:start, :note], [:num_octaves, :pos_int]],
          returns:        :ring,
          opts:           nil,
          accepts_block:  false,
          doc:            "Create a ring of successive octaves starting at `start` for `num_octaves`. ",
          examples:       [
        "(octs 60, 2)  #=> (ring 60, 72)",
        "(octs :e3, 3) #=> (ring 52, 64, 76)"
]




      def sample_free(*paths)
        paths.each do |p|
          p = [p] unless is_list_like?(p)
          filts_and_sources, _ = sample_split_filts_and_opts(p)
          resolve_sample_paths(filts_and_sources).each do |path|
            if sample_loaded?(path)
              @mod_sound_studio.free_sample([path])
              __info "Freed sample: #{unify_tilde_dir(path).inspect}"
            end
          end
        end


      end
      doc name:           :sample_free,
          introduced:     Version.new(2,9,0),
          summary:        "Free a sample on the synth server",
          args:           [[:path, :string]],
          returns:        nil,
          opts:           nil,
          accepts_block:  false,
          doc:            "Frees the memory and resources consumed by loading the sample on the server. Subsequent calls to `sample` and friends will re-load the sample on the server.

You may also specify the same set of source and filter pre-args available to `sample` itself. `sample_free` will then free all matching samples. See `sample`'s docs for more information.",
          examples:       ["
sample :loop_amen # The Amen break is now loaded into memory and played
sleep 2
sample :loop_amen # The Amen break is not loaded but played from memory
sleep 2
sample_free :loop_amen # The Amen break is freed from memory
sample :loop_amen # the Amen break is re-loaded and played",

"
puts sample_info(:loop_amen).to_i # This returns the buffer id of the sample i.e. 1
puts sample_info(:loop_amen).to_i # The buffer id remains constant whilst the sample
                                  # is loaded in memory
sample_free :loop_amen
puts sample_info(:loop_amen).to_i # The Amen break is re-loaded and gets a *new* id.",
"
sample :loop_amen
sample :ambi_lunar_land
sleep 2
sample_free :loop_amen, :ambi_lunar_land
sample :loop_amen                        # re-loads and plays amen
sample :ambi_lunar_land                  # re-loads and plays lunar land",

"# Using source and filter pre-args
dir = \"/path/to/sample/dir\"
sample_free dir # frees any loaded samples in \"/path/to/sample/dir\"
sample_free dir, 1 # frees sample with index 1 in \"/path/to/sample/dir\"
sample_free dir, :foo # frees sample with name \"foo\" in \"/path/to/sample/dir\"
sample_free dir, /[Bb]ar/ # frees sample which matches regex /[Bb]ar/ in \"/path/to/sample/dir\"

",

 ]

      def buffer(*args)
        if args.empty?
          @buffer_lookup_w_hash_syntax
        else
          @buffer_lookup_w_hash_syntax[*args]
        end
      end
      doc name:           :buffer,
          introduced:     Version.new(3,0,0),
          summary:        "Intialise or return named buffer",
          args:           [[]],
          returns:        nil,
          opts:           nil,
          accepts_block:  false,
          doc:            "Initialise or return a named buffer with a specific duration (defaults to 8 beats). Useful for working with the `:record` FX. If the buffer is requested with a different duration, then a new buffer will be initialised and the old one recycled.",
          examples:       ["
buffer(:foo) # load a 8s buffer and name it :foo
b = buffer(:foo) # return cached buffer and bind it to b
puts b.duration  #=> 8.0",
        "
buffer(:foo, 16) # load a 16s buffer and name it :foo
",
        "
use_bpm 120
buffer(:foo, 16) # load a 8s buffer and name it :foo
                 # (this isn't 16s as the BPM has been
                 # doubled from the default of 60)
",
        "
buffer(:foo)     # init a 8s buffer and name it :foo
buffer(:foo, 8)  # return cached 8s buffer (has the same duration)
buffer(:foo, 10) # init a new 10s buffer and name it :foo
buffer(:foo, 10) # return cached 10s buffer
buffer(:foo)     # init a 8s buffer and name it :foo
buffer(:foo)     # return cached 8s buffer (has the same duration)"]


      def sample_free_all
        @mod_sound_studio.free_all_samples
      end
      doc name:           :sample_free_all,
          introduced:     Version.new(2,9,0),
          summary:        "Free all loaded samples on the synth server",
          args:           [[]],
          returns:        nil,
          opts:           nil,
          accepts_block:  false,
          doc:            "Unloads all samples therefore freeing the memory and resources consumed. Subsequent calls to `sample` and friends will re-load the sample on the server.",
          examples:       ["
sample :loop_amen        # load and play :loop_amen
sample :ambi_lunar_land  # load and play :ambi_lunar_land
sleep 2
sample_free_all
sample :loop_amen        # re-loads and plays amen"]




      def start_amp_monitor
        @mod_sound_studio.start_amp_monitor
      end

      def current_amp
        @mod_sound_studio.amp
      end

      def midi_notes(*args)
        args = args.map {|a| note(a)}
        SonicPi::Core::RingVector.new(args)
      end
      doc name:           :midi_notes,
          introduced:     Version.new(2,7,0),
          summary:        "Create a ring buffer of midi note numbers",
          args:           [[:list, :array]],
          returns:        :ring,
          opts:           nil,
          accepts_block:  false,
          memoize: true,
          doc:            "Create a new immutable ring buffer of notes from args. Indexes wrap around positively and negatively. Final ring consists only of MIDI numbers and nil.",
          examples:       [
        "(midi_notes :d3, :d4, :d5) #=> (ring 50, 62, 74)",
        "(midi_notes :d3, 62,  nil) #=> (ring 50, 62, nil)"
       ]


      def rest?(n)
        case n
        when Numeric
          return false
        when Symbol
          return n == :r || n == :rest
        when NilClass
          return true
        when Hash
          if n.has_key?(:note)
            note = n[:note]
            return (note.nil? || note == :r || note == :rest)
          else
            return false
          end
        else
          return false
        end
      end
      doc name:          :rest?,
          introduced:    Version.new(2,1,0),
          summary:       "Determine if note or args is a rest",
          doc:           "Given a note or an args map, returns true if it represents a rest and false if otherwise",
          args:          [[:note_or_args, :number_symbol_or_map]],
          accepts_block: false,
          examples:      ["puts rest? nil # true",
        "puts rest? :r # true",
        "puts rest? :rest # true",
        "puts rest? 60 # false",
        "puts rest? {} # false",
        "puts rest? {note: :rest} # true",
        "puts rest? {note: nil} # true",
        "puts rest? {note: 50} # false"]


      def should_trigger?(args_h)
        return true unless args_h.key?(:on)
        on = args_h.delete(:on)
        truthy?(on)
      end

      def use_timing_guarantees(v, &block)
        raise "use_timing_guarantees does not work with a do/end block. Perhaps you meant with_timing_guarantees" if block
        __thread_locals.set(:sonic_pi_mod_sound_timing_guarantees, v)
      end
      doc name:           :use_timing_guarantees,
          introduced:     Version.new(2,10,0),
          summary:        "Inhibit synth triggers if too late",
          doc:            "If set to true, synths will not trigger if it is too late. If false, some synth triggers may be late.",
          args:           [[:bool, :true_or_false]],
          opts:           nil,
          accepts_block:  true,
          examples:       ["
use_timing_guarantees true

sample :loop_amen  #=> if time is behind by any margin, this will not trigger",
        "
use_timing_guarantees false

sample :loop_amen  #=> unless time is too far behind, this will trigger even when late."]



      def with_timing_guarantees(v, &block)
        raise "with_timing_guarantees requires a do/end block. Perhaps you meant use_timing_guarantees" unless block
        current = __thread_locals.get(:sonic_pi_mod_sound_timing_guarantees)
        __thread_locals.set(:sonic_pi_mod_sound_timing_guarantees, v)
        res = block.call
        __thread_locals.set(:sonic_pi_mod_sound_timing_guarantees, current)
        res
      end
      doc name:           :with_timing_guarantees,
          introduced:     Version.new(2,10,0),
          summary:        "Block-scoped inhibition of synth triggers if too late",
          doc:            "For the given block, if set to true, synths will not trigger if it is too late. If false, some synth triggers may be late. After the block has completed, the previous value is restored. ",
          args:           [[:bool, :true_or_false]],
          opts:           nil,
          accepts_block:  true,
          examples:       ["
with_timing_guarantees true
  sample :loop_amen  #=> if time is behind by any margin, this will not trigger
end",
"
with_timing_guarantees false
  sample :loop_amen  #=> unless time is too far behind, this will trigger even when late.
end"]


      def use_external_synths(v, &block)
        raise "use_external_synths does not work with a do/end block. Perhaps you meant with_external_synths" if block
        __thread_locals.set(:sonic_pi_mod_sound_use_external_synths, v)
      end


      def use_timing_warnings(v, &block)
        raise "use_timing_warnings does not work with a do/end block. Perhaps you meant with_timing_warnings" if block
        __thread_locals.set(:sonic_pi_mod_sound_disable_timing_warnings, !v)
      end




      def with_timing_warnings(v, &block)
        raise "with_timing_warnings requires a do/end block. Perhaps you meant use_timing_warnings" unless block
        current = __thread_locals.get(:sonic_pi_mod_sound_disable_timing_warnings)
        __thread_locals.set(:sonic_pi_mod_sound_disable_timing_warnings, !v)
        res = block.call
        __thread_locals.set(:sonic_pi_mod_sound_disable_timing_warnings, current)
        res
      end


      def use_sample_bpm(sample_name, *args)
        args_h = resolve_synth_opts_hash_or_array(args)
        num_beats = args_h[:num_beats] || 1

        # Don't use sample_duration as that is stretched to the current
        # bpm!
        sd = sample_buffer(sample_name).duration
        use_bpm(num_beats * (60.0 / sd))
      end
      doc name:           :use_sample_bpm,
          introduced:     Version.new(2,1,0),
          summary:        "Sample-duration-based bpm modification",
          doc:            "Modify bpm so that sleeping for 1 will sleep for the duration of the sample.",
          args:           [[:string_or_number, :sample_name_or_duration]],
          opts:           {:num_beats => "The number of beats within the sample. By default this is 1."},
          accepts_block:  false,
          examples:       ["use_sample_bpm :loop_amen  #Set bpm based on :loop_amen duration

live_loop :dnb do
  sample :bass_dnb_f
  sample :loop_amen
  sleep 1                  #`sleep`ing for 1 actually sleeps for duration of :loop_amen
end",
        "
use_sample_bpm :loop_amen, num_beats: 4  # Set bpm based on :loop_amen duration
                                         # but also specify that the sample duration
                                         # is actually 4 beats long.

live_loop :dnb do
  sample :bass_dnb_f
  sample :loop_amen
  sleep 4                  #`sleep`ing for 4 actually sleeps for duration of :loop_amen
                           # as we specified that the sample consisted of
                           # 4 beats
end"]




      def with_sample_bpm(sample_name, *args, &block)
        raise "with_sample_bpm must be called with a do/end block" unless block
        args_h = resolve_synth_opts_hash_or_array(args)
        num_beats = args_h[:num_beats] || 1
        # Don't use sample_duration as that is stretched to the current
        # bpm!
        sd = sample_buffer(sample_name).duration
        with_bpm(num_beats * (60.0 / sd), &block)
      end
      doc name:           :with_sample_bpm,
          introduced:     Version.new(2,1,0),
          summary:        "Block-scoped sample-duration-based bpm modification",
          doc:            "Block-scoped modification of bpm so that sleeping for 1 will sleep for the duration of the sample.",
          args:           [[:string_or_number, :sample_name_or_duration]],
          opts:           {:num_beats => "The number of beats within the sample. By default this is 1."},
          accepts_block:  true,
          requires_block: true,
          examples:       ["
live_loop :dnb do
  with_sample_bpm :loop_amen do #Set bpm based on :loop_amen duration
    sample :bass_dnb_f
    sample :loop_amen
    sleep 1                     #`sleep`ing for 1 sleeps for duration of :loop_amen
  end
end",
        "live_loop :dnb do
  with_sample_bpm :loop_amen, num_beats: 4 do # Set bpm based on :loop_amen duration
                                              # but also specify that the sample duration
                                              # is actually 4 beats long.
    sample :bass_dnb_f
    sample :loop_amen
    sleep 4                     #`sleep`ing for 4 sleeps for duration of :loop_amen
                                # as we specified that the sample consisted of
                                # 4 beats
  end
end"]




      def use_arg_bpm_scaling(bool, &block)
        raise "use_arg_bpm_scaling does not work with a block. Perhaps you meant with_arg_bpm_scaling" if block
        __thread_locals.set(:sonic_pi_spider_arg_bpm_scaling, bool)
      end
      doc name:           :use_arg_bpm_scaling,
          introduced:     Version.new(2,0,0),
          summary:        "Enable and disable BPM scaling",
          doc:            "Turn synth argument bpm scaling on or off for the current thread. This is on by default. Note, using `rt` for args will result in incorrect times when used after turning arg bpm scaling off.",
          args:           [[:bool, :boolean]],
          opts:           nil,
          accepts_block:  false,
          examples:       ["
use_bpm 120
play 50, release: 2 # release is actually 1 due to bpm scaling
sleep 2             # actually sleeps for 1 second
use_arg_bpm_scaling false
play 50, release: 2 # release is now 2
sleep 2             # still sleeps for 1 second",

        "                       # Interaction with rt
use_bpm 120
play 50, release: rt(2) # release is 2 seconds
sleep rt(2)             # sleeps for 2 seconds
use_arg_bpm_scaling false
play 50, release: rt(2) # ** Warning: release is NOT 2 seconds! **
sleep rt(2)             # still sleeps for 2 seconds"]





      def with_arg_bpm_scaling(bool, &block)
        raise "with_arg_bpm_scaling must be called with a do/end block. Perhaps you meant use_arg_bpm_scaling" unless block
        current_scaling = __thread_locals.get(:sonic_pi_spider_arg_bpm_scaling)

        __thread_locals.set(:sonic_pi_spider_arg_bpm_scaling, bool)
        res = block.call
        __thread_locals.set(:sonic_pi_spider_arg_bpm_scaling, current_scaling)
        res
      end
      doc name:           :with_arg_bpm_scaling,
          introduced:     Version.new(2,0,0),
          summary:        "Block-level enable and disable BPM scaling",
          doc:            "Turn synth argument bpm scaling on or off for the supplied block. Note, using `rt` for args will result in incorrect times when used within this block.",
          args:           [],
          opts:           nil,
          accepts_block:  true,
          requires_block: true,
          examples:       ["use_bpm 120
play 50, release: 2 # release is actually 1 due to bpm scaling
with_arg_bpm_scaling false do
  play 50, release: 2 # release is now 2
end",

        "                         # Interaction with rt
use_bpm 120
play 50, release: rt(2)   # release is 2 seconds
sleep rt(2)               # sleeps for 2 seconds
with_arg_bpm_scaling false do
  play 50, release: rt(2) # ** Warning: release is NOT 2 seconds! **
  sleep rt(2)             # still sleeps for 2 seconds
end"]


      def pitch_ratio(*args)
        raise "The fn pitch_ratio has been renamed. Please use the new name: pitch_to_ratio"
      end

      def pitch_to_ratio(m)
        2.0 ** (m.to_f / 12.0)
      end
      doc name:          :pitch_to_ratio,
          introduced:    Version.new(2,5,0),
          summary:       "relative MIDI pitch to frequency ratio",
          doc:           "Convert a midi note to a ratio which when applied to a frequency will scale the frequency by the number of semitones. Useful for changing the pitch of a sample by using it as a way of generating the rate.",
          args:          [[:pitch, :midi_number]],
          opts:          nil,
          accepts_block: false,
          examples:      [
        "pitch_to_ratio 12 #=> 2.0",
        "pitch_to_ratio 1 #=> 1.05946",
        "pitch_to_ratio -12 #=> 0.5",
        "sample :ambi_choir, rate: pitch_to_ratio(3) # Plays :ambi_choir 3 semitones above default.",
        "
# Play a chromatic scale of semitones
(range 0, 16).each do |n|                  # For each note in the range 0->16
  sample :ambi_choir, rate: pitch_to_ratio(n) # play :ambi_choir at the relative pitch
  sleep 0.5                                # and wait between notes
end"
      ]




      def ratio_to_pitch(r)
        12.0 * Math.log2(r.abs.to_f)
      end
      doc name:          :ratio_to_pitch,
          introduced:    Version.new(2,7,0),
          summary:       "relative frequency ratio to MIDI pitch",
          doc:           "Convert a frequency ratio to a midi note which when added to a note will transpose the note to match the frequency ratio.",
          args:          [[:ratio, :number]],
          opts:          nil,
          accepts_block: false,
          examples:      [
        "ratio_to_pitch 2 #=> 12.0",
        "ratio_to_pitch 0.5 #=> -12.0"

      ]




      def midi_to_hz(n)
        n = note(n) unless n.is_a? Numeric
        440.0 * (2 ** ((n - 69) / 12.0))
      end
      doc name:          :midi_to_hz,
         introduced:    Version.new(2,0,0),
         summary:       "MIDI to Hz conversion",
         doc:           "Convert a midi note to hz",
         args:          [[:note, :symbol_or_number]],
         opts:          nil,
         accepts_block: false,
         examples:      ["midi_to_hz(60) #=> 261.6256"]




      def hz_to_midi(freq)
        (12 * (Math.log(freq * 0.0022727272727) / Math.log(2))) + 69
      end
      doc name:          :hz_to_midi,
          introduced:    Version.new(2,0,0),
          summary:       "Hz to MIDI conversion",
          doc:           "Convert a frequency in hz to a midi note. Note that the result isn't an integer and there is a potential for some very minor rounding errors.",
          args:          [[:freq, :number]],
          opts:          nil,
          accepts_block: false,
          examples:      ["hz_to_midi(261.63) #=> 60.0003"]


      def set_recording_bit_depth!(d)
        @mod_sound_studio.bit_depth = d
        __info "Recording bit depth set to #{d}"
      end
      doc name:          :set_recording_bit_depth!,
          introduced:    Version.new(2,11,0),
          summary:       "Set the bit depth for recording wav files",
          doc:           "When you hit the record button, Sonic Pi saves all the audio you can hear into a wav file. By default, this file uses a resolution of 16 bits which is the same as CD audio and good enough for most use cases. However, when working with professional equipment, it is common to want to work with even higher quality files such as 24 bits and even 32 bits. This function allows you to switch the default from 16 to one of 8, 16, 24 or 32.",
          args:          [[:bit_depth, :number]],
          opts:          nil,
          modifies_env: true,
          accepts_block: false,
          examples:      [
        "
set_recording_bit_depth! 24                 # Set recording bit depth to 24"]


      def set_control_delta!(t)
        @mod_sound_studio.control_delta = t
        __info "Control delta set to #{t}"
      end
      doc name:          :set_control_delta!,
          introduced:    Version.new(2,1,0),
          summary:       "Set control delta globally",
          doc:           "Specify how many seconds between successive modifications (i.e. trigger then controls) of a specific node on a specific thread. Set larger if you are missing control messages sent extremely close together in time.",
          args:          [[:time, :number]],
          opts:          nil,
          modifies_env: true,
          accepts_block: false,
          examples:      [
        "
set_control_delta! 0.1                 # Set control delta to 0.1

s = play 70, release: 8, note_slide: 8 # Play a note and set the slide time
control s, note: 82                    # immediately start sliding note.
                                       # This control message might not be
                                       # correctly handled as it is sent at the
                                       # same virtual time as the trigger.
                                       # If you don't hear a slide, try increasing the
                                       # control delta until you do."]







      def use_debug(v, &block)
        raise "use_debug does not work with a do/end block. Perhaps you meant with_debug" if block
        __thread_locals.set(:sonic_pi_mod_sound_synth_silent, !v)
      end
      doc name:          :use_debug,
          introduced:    Version.new(2,0,0),
          summary:       "Enable and disable debug",
          doc:           "Enable or disable messages created on synth triggers. If this is set to false, the synths will be silent until debug is turned back on. Silencing debug messages can reduce output noise and also increase performance on slower platforms. See `with_debug` for setting the debug value only for a specific `do`/`end` block.",
          args:          [[:true_or_false, :boolean]],
          opts:          nil,
          accepts_block: false,
          examples:      ["use_debug true # Turn on debug messages", "use_debug false # Disable debug messages"]




      def with_debug(v, &block)
        raise "with_debug requires a do/end block. Perhaps you meant use_debug" unless block
        current = __thread_locals.get(:sonic_pi_mod_sound_synth_silent)
        __thread_locals.set(:sonic_pi_mod_sound_synth_silent, !v)
        res = block.call
        __thread_locals.set(:sonic_pi_mod_sound_synth_silent, current)
       res
      end
      doc name:          :with_debug,
          introduced:    Version.new(2,0,0),
          summary:       "Block-level enable and disable debug",
          doc:           "Similar to use_debug except only applies to code within supplied `do`/`end` block. Previous debug value is restored after block.",
          args:          [[:true_or_false, :boolean]],
          opts:          nil,
          accepts_block: true,
          requires_block: true,
          examples:      ["
# Turn on debugging:
use_debug true

play 80 # Debug message is sent

with_debug false do
  #Debug is now disabled
  play 50 # Debug message is not sent
  sleep 1
  play 72 # Debug message is not sent
end

# Debug is re-enabled
play 90 # Debug message is sent

"]




      def use_arg_checks(v, &block)
        raise "use_arg_checks does not work with a do/end block. Perhaps you meant with_arg_checks" if block

        __thread_locals.set(:sonic_pi_mod_sound_check_synth_args, !!v)
      end
      doc name:          :use_arg_checks,
          introduced:    Version.new(2,0,0),
          summary:       "Enable and disable arg checks",
          doc:           "When triggering synths, each argument is checked to see if it is sensible. When argument checking is enabled and an argument isn't sensible, you'll see an error in the debug pane. This setting allows you to explicitly enable and disable the checking mechanism. See with_arg_checks for enabling/disabling argument checking only for a specific `do`/`end` block.",
          args:          [[:true_or_false, :boolean]],
          opts:          nil,
          accepts_block: false,
          examples:      ["
play 50, release: 5 # Args are checked
use_arg_checks false
play 50, release: 5 # Args are not checked"]




      def with_arg_checks(v, &block)
        raise "with_arg_checks requires a do/end block. Perhaps you meant use_arg_checks" unless block

        current = __thread_locals.get(:sonic_pi_mod_sound_check_synth_args)
        __thread_locals.set(:sonic_pi_mod_sound_check_synth_args, v)
        res = block.call
        __thread_locals.set(:sonic_pi_mod_sound_check_synth_args, current)
        res
      end
      doc name:           :with_arg_checks,
          introduced:     Version.new(2,0,0),
          summary:        "Block-level enable and disable arg checks",
          doc:            "Similar to `use_arg_checks` except only applies to code within supplied `do`/`end` block. Previous arg check value is restored after block.",
          args:           [[:true_or_false, :boolean]],
          opts:           nil,
          accepts_block:  true,
          requires_block: true,
          examples:       ["
# Turn on arg checking:
use_arg_checks true

play 80, cutoff: 100 # Args are checked

with_arg_checks false do
  #Arg checking is now disabled
  play 50, release: 3 # Args are not checked
  sleep 1
  play 72             # Arg is not checked
end

# Arg checking is re-enabled
play 90 # Args are checked

"]

      def set_cent_tuning!(shift)
        @mod_sound_studio.cent_tuning = shift
      end
      doc name:          :set_cent_tuning!,
          introduced:    Version.new(2,10,0),
          summary:       "Global Cent tuning",
          doc:           "Globally tune Sonic Pi to play with another external instrument.

Uniformly tunes your music by shifting all notes played by the specified number of cents. To shift up by a cent use a cent tuning of 1. To shift down use negative numbers. One semitone consists of 100 cents.

See `use_cent_tuning` for setting the cent tuning value locally for a specific thread or `live_loop`. This is a global value and will shift the tuning for *all* notes. It will also persist for the entire session.

Important note: the cent tuning set by `set_cent_tuning!` is independent of any thread-local cent tuning values set by `use_cent_tuning` or `with_cent_tuning`. ",
          args:          [[:cent_shift, :number]],
          opts:          nil,
          accepts_block: false,
          intro_fn:       false,
          examples:      ["
play 50 # Plays note 50
set_cent_tuning! 1
play 50 # Plays note 50.01"]

      def use_cent_tuning(shift, &block)
        raise "use_cent_tuning does not work with a do/end block. Perhaps you meant with_cent_tuning" if block
        raise "Cent tuning value must be a number, got #{shift.inspect}" unless shift.is_a?(Numeric)
        __thread_locals.set(:sonic_pi_mod_sound_cent_tuning, shift)
      end
      doc name:          :use_cent_tuning,
          introduced:    Version.new(2,9,0),
          summary:       "Cent tuning",
          doc:           "Uniformly tunes your music by shifting all notes played by the specified number of cents. To shift up by a cent use a cent tuning of 1. To shift down use negative numbers. One semitone consists of 100 cents.

See `with_cent_tuning` for setting the cent tuning value only for a specific `do`/`end` block. To transpose entire semitones see `use_transpose`.",
          args:          [[:cent_shift, :number]],
          opts:          nil,
          accepts_block: false,
          intro_fn:       true,
          examples:      ["
play 50 # Plays note 50
use_cent_tuning 1
play 50 # Plays note 50.01"]




      def with_cent_tuning(shift, &block)
        raise "with_cent_tuning requires a do/end block. Perhaps you meant use_cent_tuning" unless block
        raise "Cent tuning value must be a number, got #{shift.inspect}" unless shift.is_a?(Numeric)
        curr = __thread_locals.get(:sonic_pi_mod_sound_cent_tuning)
        __thread_locals.set(:sonic_pi_mod_sound_cent_tuning, shift)
        res = block.call
        __thread_locals.set(:sonic_pi_mod_sound_cent_tuning, curr)
        res
      end
      doc name:           :with_cent_tuning,
          introduced:     Version.new(2,9,0),
          summary:        "Block-level cent tuning",
          doc:            "Similar to `use_cent_tuning` except only applies cent shift to code within supplied `do`/`end` block. Previous cent tuning value is restored after block. One semitone consists of 100 cents. To transpose entire semitones see `with_transpose`.",
          args:           [[:cent_shift, :number]],
          opts:           nil,
          accepts_block:  true,
          requires_block: true,
          examples:       ["
use_cent_tuning 1
play 50 # Plays note 50.01

with_cent_tuning 2 do
  play 50 # Plays note 50.02
end

# Original cent tuning value is restored
play 50 # Plays note 50.01

"]



      def use_octave(shift, &block)
        raise "use_octave does not work with a do/end block. Perhaps you meant with_octave" if block
        raise "Octave shift must be a number, got #{shift.inspect}" unless shift.is_a?(Numeric)
        __thread_locals.set(:sonic_pi_mod_sound_octave_shift, shift)
      end
      doc name:          :use_octave,
          introduced:    Version.new(2,9,0),
          summary:       "Note octave transposition",
          doc:           "Transposes your music by shifting all notes played by the specified number of octaves. To shift up by an octave use a transpose of 1. To shift down use negative numbers. See `with_octave` for setting the octave shift only for a specific `do`/`end` block. For transposing the notes within the octave range see `use_transpose`.",
          args:          [[:octave_shift, :number]],
          opts:          nil,
          accepts_block: false,
          intro_fn:      true,
          examples:      ["
play 50 # Plays note 50
use_octave 1
play 50 # Plays note 62",

        "
# You may change the transposition multiple times:
play 62 # Plays note 62
use_octave -1
play 62 # Plays note 50
use_octave 2
play 62 # Plays note 86"]



      def with_octave(shift, &block)
        raise "with_octave requires a do/end block. Perhaps you meant use_octave" unless block
        raise "Octave shift must be a number, got #{shift.inspect}" unless shift.is_a?(Numeric)
        curr = __thread_locals.get(:sonic_pi_mod_sound_octave_shift)
        __thread_locals.set(:sonic_pi_mod_sound_octave_shift, shift)
        res = block.call
        __thread_locals.set(:sonic_pi_mod_sound_octave_shift, curr)
        res
      end
      doc name:          :with_octave,
          introduced:    Version.new(2,9,0),
          summary:       "Block level octave transposition",
          doc:           "Transposes your music by shifting all notes played by the specified number of octaves within the specified block. To shift up by an octave use a transpose of 1. To shift down use negative numbers. For transposing the notes within the octave range see `with_transpose`.",
          args:          [[:octave_shift, :number]],
          opts:          nil,
          accepts_block: true,
          intro_fn:      true,
          examples:      ["
play 50 # Plays note 50
sleep 1
with_octave 1 do
 play 50 # Plays note 62
end
sleep 1
play 50 # Plays note 50"]




      def use_transpose(shift, &block)
        raise "use_transpose does not work with a do/end block. Perhaps you meant with_transpose" if block
        raise "Transpose value must be a number, got #{shift.inspect}" unless shift.is_a?(Numeric)
        __thread_locals.set(:sonic_pi_mod_sound_transpose, shift)
      end
      doc name:          :use_transpose,
          introduced:    Version.new(2,0,0),
          summary:       "Note transposition",
          doc:           "Transposes your music by shifting all notes played by the specified amount. To shift up by a semitone use a transpose of 1. To shift down use negative numbers. See `with_transpose` for setting the transpose value only for a specific `do`/`end` block. To transpose entire octaves see `use_octave`.",
          args:          [[:note_shift, :number]],
          opts:          nil,
          accepts_block: false,
          intro_fn:       true,
          examples:      ["
play 50 # Plays note 50
use_transpose 1
play 50 # Plays note 51",

        "
# You may change the transposition multiple times:
play 62 # Plays note 62
use_transpose -12
play 62 # Plays note 50
use_transpose 3
play 62 # Plays note 65"]




      def with_transpose(shift, &block)
        raise "with_transpose requires a do/end block. Perhaps you meant use_transpose" unless block
        raise "Transpose value must be a number, got #{shift.inspect}" unless shift.is_a?(Numeric)
        curr = __thread_locals.get(:sonic_pi_mod_sound_transpose)
        __thread_locals.set(:sonic_pi_mod_sound_transpose, shift)
        res = block.call
        __thread_locals.set(:sonic_pi_mod_sound_transpose, curr)
        res
      end
      doc name:           :with_transpose,
          introduced:     Version.new(2,0,0),
          summary:        "Block-level note transposition",
          doc:            "Similar to use_transpose except only applies to code within supplied `do`/`end` block. Previous transpose value is restored after block. To transpose entire octaves see `with_octave`.",
          args:           [[:note_shift, :number]],
          opts:           nil,
          accepts_block:  true,
          requires_block: true,
          examples:       ["
use_transpose 3
play 62 # Plays note 65

with_transpose 12 do
  play 50 # Plays note 62
  sleep 1
  play 72 # Plays note 84
end

# Original transpose value is restored
play 80 # Plays note 83

"]

      def use_tuning(tuning, fundamental_note = :c, &block)
        raise "use_tuning does not work with a do/end block. Perhaps you meant with_tuning" if block
        raise "tuning value must be a symbol like :just or :equal, got #{tuning.inspect}" unless tuning.is_a?(Symbol)
        __thread_locals.set(:sonic_pi_mod_sound_tuning, [tuning, fundamental_note].freeze)
      end
      doc name:          :use_tuning,
          introduced:    Version.new(2,6,0),
          summary:       "Use alternative tuning systems",
          doc:           "In most music we make semitones by dividing the octave into 12 equal parts, which is known as equal temperament. However there are lots of other ways to tune the 12 notes. This method adjusts each midi note into the specified tuning system. Because the ratios between notes aren't always equal, be careful to pick a centre note that is in the key of the music you're making for the best sound. Currently available tunings are `:just`, `:pythagorean`, `:meantone` and the default of `:equal`",
          args:          [[:tuning, :symbol], [:fundamental_note, :symbol_or_number]],
          opts:          nil,
          accepts_block: false,
          examples:      ["
play :e4 # Plays note 64
use_tuning :just, :c
play :e4 # Plays note 63.8631
# transparently changes midi notes too
play 64 # Plays note 63.8631",

        "
# You may change the tuning multiple times:
play 64 # Plays note 64
use_tuning :just
play 64 # Plays note 63.8631
use_tuning :equal
play 64 # Plays note 64"]



      def with_tuning(tuning, fundamental_note = :c, &block)
        raise "with_tuning requires a do/end block. Perhaps you meant use_tuning" unless block
        raise "tuning value must be a symbol like :just or :equal, got #{tuning.inspect}" unless tuning.is_a?(Symbol)
        curr_tuning_info = __thread_locals.get(:sonic_pi_mod_sound_tuning)
        __thread_locals.set(:sonic_pi_mod_sound_tuning, [tuning, fundamental_note].freeze)
        res = block.call
        __thread_locals.set(:sonic_pi_mod_sound_tuning, curr_tuning_info)
        res
      end
      doc name:          :with_tuning,
          introduced:    Version.new(2,6,0),
          summary:       "Block-level tuning modification",
          doc:           "Similar to use_tuning except only applies to code within supplied `do`/`end` block. Previous tuning value is restored after block.",
          args:          [[:tuning, :symbol], [:fundamental_note, :symbol_or_number]],
          opts:          nil,
          accepts_block: true,
          examples:      ["
use_tuning :equal, :c
play :e4 # Plays note 64
with_tuning :just, :c do
  play :e4 # Plays note 63.8631
  sleep 1
  play :c4 # Plays note 60
end
# Original tuning value is restored
play :e4 # Plays note 64"]


      def use_synth(synth_name, *args, &block)
        raise "use_synth does not accept opts such as #{arg_h_pp(resolve_synth_opts_hash_or_array(args))}. \n Consider using use_synth_defaults." unless args.empty?
        raise "use_synth does not work with a do/end block. Perhaps you meant with_synth" if block
        set_current_synth synth_name
      end
      doc name:          :use_synth,
          introduced:    Version.new(2,0,0),
          summary:       "Switch current synth",
          doc:           "Switch the current synth to `synth_name`. Affects all further calls to `play`. See `with_synth` for changing the current synth only for a specific `do`/`end` block.",
          args:          [[:synth_name, :symbol]],
          opts:          nil,
          accepts_block: false,
          intro_fn:       true,
          examples:      ["
play 50 # Plays with default synth
use_synth :mod_sine
play 50 # Plays with mod_sine synth"]




      def with_synth(synth_name, *args, &block)
        raise "with_synth does not accept opts such as #{arg_h_pp(resolve_synth_opts_hash_or_array(args))}. \n Consider using with_synth_defaults." unless args.empty?
        raise "with_synth must be called with a do/end block. Perhaps you meant use_synth" unless block
        orig_synth = current_synth_name
        set_current_synth synth_name
        res = block.call
        set_current_synth orig_synth
        res
      end
      doc name:           :with_synth,
          introduced:     Version.new(2,0,0),
          summary:        "Block-level synth switching",
          doc:            "Switch the current synth to `synth_name` but only for the duration of the `do`/`end` block. After the `do`/`end` block has completed, the previous synth is restored.",
          args:           [[:synth_name, :symbol]],
          opts:           nil,
          accepts_block:  true,
          requires_block: true,
          examples:      ["
play 50 # Plays with default synth
sleep 2
use_synth :supersaw
play 50 # Plays with supersaw synth
sleep 2
with_synth :saw_beep do
  play 50 # Plays with saw_beep synth
end
sleep 2
# Previous synth is restored
play 50 # Plays with supersaw synth
"]




      def recording_start
        if @mod_sound_studio.recording?
          __info "Already recording..."
        else
          __info "Start recording"
          tmp_dir = Dir.mktmpdir("sonic-pi")
          @tmp_path = File.expand_path("#{tmp_dir}/#{Random.rand(100000000)}.wav")
          @mod_sound_studio.recording_start @tmp_path
        end
      end
      doc name:          :recording_start,
          introduced:    Version.new(2,0,0),
          summary:       "Start recording",
          doc:           "Start recording all sound to a `.wav` file stored in a temporary directory.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      [],
          hide:          true




      def recording_stop
        if @mod_sound_studio.recording?
          __info "Stop recording"
          @mod_sound_studio.recording_stop
        else
          __info "Recording already stopped"
        end
      end
      doc name:          :recording_stop,
          introduced:    Version.new(2,0,0),
          summary:       "Stop recording",
          doc:           "Stop current recording.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      [],
          hide:          true




      def recording_save(filename)
        __info "Stop recording" if @mod_sound_studio.recording_stop
        if @tmp_path && File.exist?(@tmp_path)
          FileUtils.mv(@tmp_path, filename)
          @tmp_path = nil
          __info "Saving recording to #{filename}"
        else
          __info "No recording to save"
        end
      end
      doc name:          :recording_save,
          introduced:    Version.new(2,0,0),
          summary:       "Save recording",
          doc:           "Save previous recording to the specified location",
          args:          [[:path, :string]],
          opts:          nil,
          accepts_block: false,
          examples:      [],
          hide:          true




      def recording_delete
        __info "Deleting recording..."
        FileUtils.rm @tmp_path if @tmp_path
      end
      doc name:          :recording_delete,
          doc:           "After using `recording_start` and `recording_stop`, a temporary file is created until you decide to use `recording_save`. If you've decided you don't want to save it you can use this method to delete the temporary file straight away, otherwise the operating system will take care of deleting it later.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      [],
          hide:          true




      def reset_mixer!()
        @mod_sound_studio.mixer_reset
      end
      doc name:          :reset_mixer!,
          introduced:    Version.new(2,9,0),
          summary:       "Reset master mixer",
          doc:           "The master mixer is the final mixer that all sound passes through. This fn resets it to its default set - undoing any changes made via set_mixer_control!",
          args:          [],
          opts:          {},
          accepts_block: false,
          examples:      ["
set_mixer_control! lpf: 70 # LPF cutoff value of master mixer is now 70
sample :loop_amen          # :loop_amen sample is played with low cutoff
sleep 3
reset_mixer!               # mixer is now reset to default values
sample :loop_amen          # :loop_amen sample is played with normal cutoff"]




      def set_mixer_control!(opts)
        @mod_sound_studio.mixer_control(opts)
      end
      doc name:          :set_mixer_control!,
          introduced:    Version.new(2,7,0),
          summary:       "Control master mixer",
          doc:           "The master mixer is the final mixer that all sound passes through. This fn gives you control over the master mixer allowing you to manipulate all the sound playing through Sonic Pi at once. For example, you can sweep a lpf or hpf over the entire sound. You can reset the controls back to their defaults with `reset_mixer!`.",
          args:          [],
          opts:          {pre_amp:        "Controls the amplitude of the signal prior to the FX stage of the mixer (prior to lpf/hpf stages). Has slide opts. Default 1.",
                          amp:            "Controls the amplitude of the signal after the FX stage. Has slide opts. Default 1.",
                          hpf:            "Global hpf FX. Has slide opts. Default 0.",
                          lpf:            "Global lpf FX. Has slide opts. Default 135.5.",
                          hpf_bypass:     "Bypass the global hpf. 0=no bypass, 1=bypass. Default 0.",
                          lpf_bypass:     "Bypass the global lpf. 0=no bypass, 1=bypass. Default 0.",
                          limiter_bypass: "Bypass the final limiter. 0=no bypass, 1=bypass. Default 0.",
                          leak_dc_bypass: "Bypass the final DC leak correction FX. 0=no bypass, 1=bypass. Default 0."},
          accepts_block: false,
          examples:      ["
set_mixer_control! lpf: 30, lpf_slide: 16 # slide the global lpf to 30 over 16 beats."]




      def set_mixer_invert_stereo!
        @mod_sound_studio.mixer_invert_stereo(true)
      end

      def set_mixer_standard_stereo!
        @mod_sound_studio.mixer_invert_stereo(false)
      end

      def set_mixer_stereo_mode!
        @mod_sound_studio.mixer_stereo_mode
      end

      def set_mixer_mono_mode!
        @mod_sound_studio.mixer_mono_mode
      end


      def synth(synth_name, *args, &blk)
        synth_name = current_synth unless synth_name
        sn_sym = synth_name.to_sym
        info = Synths::SynthInfo.get_info(sn_sym)
        raise "Unknown synth #{sn_sym.inspect}" unless info || __thread_locals.get(:sonic_pi_mod_sound_use_external_synths)


        args_h = resolve_synth_opts_hash_or_array(args)
        tls = __thread_locals.get(:sonic_pi_mod_sound_synth_defaults) || {}

        args_h = tls.merge(args_h).to_h

        if rest? args_h
          unless __thread_locals.get(:sonic_pi_mod_sound_synth_silent)
            __delayed_message "synth #{synth_name.to_sym.inspect}, {note: :rest}"
          end
          return BlankNode.new(args_h)
        end

        if info
          # only munge around with :note and notes if
          # this is a built-in synth.
          notes = args_h[:notes] || args_h[:note]
          if is_list_like?(notes)
            args_h.delete(:notes)
            args_h.delete(:note)
            shifted_notes = notes.map {|n| normalise_transpose_and_tune_note_from_args(n, args_h)}
            return trigger_chord(synth_name, shifted_notes, args_h)
          end

          n = args_h[:note] || 52
          n = normalise_transpose_and_tune_note_from_args(n, args_h)


          args_h[:note] = n
        end
        res_node = trigger_inst synth_name, args_h, info
        t = nil
        if block_given?
          t = in_thread do
            blk.call(res_node)
          end
        end

        if t
          res_node.on_destroyed do
            t.kill
          end
        end
        res_node
      end
      doc name:          :synth,
          introduced:    Version.new(2,0,0),
          summary:       "Trigger specific synth",
          doc:           "Trigger specified synth with given opts. Bypasses `current_synth` value, yet still honours `current_synth_defaults`. When using `synth`, the note is no longer an explicit argument but an opt with the key `note:`.

If note: opt is `nil`, `:r` or `:rest`, play is ignored and treated as a rest. Also, if the `on:` opt is specified and returns `false`, or `nil` then play is similarly ignored and treated as a rest.

If the synth name is `nil` behaviour is identical to that of `play` in that the `current_synth` will determine the actual synth triggered.

If a block is given, it is assumed to take one arg which will be the controllable synth node and the body of the block is run in an implicit `in_thread`. This allows for asynchronous control of the synth without interferring with time. For synchronous control capture the result of `synth` as a variable and use that.

Note that the default opts listed are only a guide to the most common opts across all the synths. Not all synths support all the default opts and each synth typically supports many more opts specific to that synth. For example, the `:tb303` synth supports 45 unique opts. For a full list of a synth's opts see its documentation in the Help system. This can be accessed directly by clicking on the name of the synth and using the shortcut `C-i`",
          args:          [[:synth_name, :symbol]],
          opts:          DEFAULT_PLAY_OPTS,
          accepts_block: true,
          examples:      [
"
use_synth :beep            # Set current synth to :beep
play 60                    # Play note 60 with opt defaults

synth :dsaw, note: 60    # Bypass current synth and play :dsaw
                         # with note 60 and opt defaults ",
"
synth :fm, note: 60, amp: 0.5 # Play note 60 of the :fm synth with an amplitude of 0.5",

        "
use_synth_defaults release: 5
synth :dsaw, note: 50 # Play note 50 of the :dsaw synth with a release of 5",
"# You can play chords with the notes: opt:
synth :dsaw, notes: (chord :e3, :minor)",
"
# on: vs if
notes = (scale :e3, :minor_pentatonic, num_octaves: 2)

live_loop :rhyth do
  8.times do
    trig = (spread 3, 7).tick(:rhyth)
    synth :tri, on: trig, note: notes.tick, release: 0.1  # Here, we're calling notes.tick
                                                          # every time we attempt to play the synth
                                                          # so the notes rise faster than rhyth2
    sleep 0.125
  end
end


live_loop :rhyth2 do
  8.times do
    trig = (spread 3, 7).tick(:rhyth)
    synth :saw, note: notes.tick, release: 0.1 if trig  # Here, we're calling notes.tick
                                                        # only when the spread says to play
                                                        # so the notes rise slower than rhyth
    sleep 0.125
  end
end
",
" # controlling a synth synchronously
s = synth :beep, note: :e3, release: 4
sleep 1
control s, note: :e5
sleep 0.5
synth :dsaw, note: :e3   # This is triggered after 1.5s from start",

" # Controlling a synth asynchronously
synth :beep, note: :e3, release: 4 do |s|
  sleep 1                                               # This block is run in an implicit in_thread
  control s, note: :e5                                  # and therefore is asynchronous
end

sleep 0.5
synth :dsaw, note: :e3 # This is triggered after 0.5s from start"

      ]



      def play(n, *args, &blk)
        if n.is_a?(Hash) && args.empty?
          synth nil, n, &blk
        else
          synth nil, {note: n}, *args, &blk
        end
      end
      doc name:          :play,
          introduced:    Version.new(2,0,0),
          summary:       "Play current synth",
          doc:           "Play note with current synth. Accepts a set of standard options which include control of an amplitude envelope with `attack:`, `decay:`, `sustain:` and `release:` phases. These phases are triggered in order, so the duration of the sound is attack + decay + sustain + release times. The duration of the sound does not affect any other notes. Code continues executing whilst the sound is playing through its envelope phases.

If `duration:` is supplied and `sustain:` isn't, it causes `sustain:` to be set so that all four phases add up to the duration.

Accepts optional args for modification of the synth being played. See each synth's documentation for synth-specific opts. See `use_synth` and `with_synth` for changing the current synth.

If note is `nil`, `:r` or `:rest`, play is ignored and treated as a rest. Also, if the `on:` opt is specified and returns `false`, or `nil` then play is similarly ignored and treated as a rest.

Note that the default opts listed are only a guide to the most common opts across all the synths. Not all synths support all the default opts and each synth typically supports many more opts specific to that synth. For example, the `:tb303` synth supports 45 unique opts. For a full list of a synth's opts see its documentation in the Help system.
    ",
          args:          [[:note, :symbol_or_number]],
          opts:          DEFAULT_PLAY_OPTS,
          accepts_block: true,
          intro_fn:      true,
          examples:      ["
play 50 # Plays note 50 on the current synth",

        "play 50, attack: 1 # Plays note 50 with a fade-in time of 1s",

        "play 62, pan: -1, release: 3 # Play note 62 in the left ear with a fade-out time of 3s.",

      " # controlling a synth synchronously
s = play :e3, release: 4
sleep 1
control s, note: :e5
sleep 0.5
use_synth :dsaw
play :e3   # This is triggered after 1.5s from start",

" # Controlling a synth asynchronously
play :e3, release: 4 do |s|
  sleep 1                                               # This block is run in an implicit in_thread
  control s, note: :e5                                  # and therefore is asynchronous
end

sleep 0.5
use_synth :dsaw
play :e3 # This is triggered after 0.5s from start"]




      def play_pattern(notes, *args)
        play_pattern_timed(notes, 1, *args)
      end
      doc name:          :play_pattern,
          introduced:    Version.new(2,0,0),
          summary:       "Play pattern of notes",
          doc:           "Play list of notes with the current synth one after another with a sleep of 1

Accepts optional args for modification of the synth being played. See each synth's documentation for synth-specific opts. See use_synth and with_synth for changing the current synth.",
          args:          [[:notes, :list]],
          opts:          {},
          accepts_block: false,
          examples:      ["
play_pattern [40, 41, 42] # Same as:
                          #   play 40
                          #   sleep 1
                          #   play 41
                          #   sleep 1
                          #   play 42
",
        "play_pattern [:d3, :c1, :Eb5] # You can use keyword notes",

        "play_pattern [:d3, :c1, :Eb5], amp: 0.5, cutoff: 90 # Supports the same arguments as play:"]




      def play_pattern_timed(notes, times, *args)
        if is_list_like?(times)
          t = times.ring
          notes.each_with_index do |note, idx|
            kwargs = if args.last.is_a?(Hash) then args.last else {} end
            duration = t[idx]
            kwargs[:duration] = duration
            play(note, *[kwargs])
            sleep(duration)
          end
        else
          play_pattern_timed(notes, [times], *args)
        end
      end
      doc name:          :play_pattern_timed,
          introduced:    Version.new(2,0,0),
          summary:       "Play pattern of notes with specific times",
          doc:           "Play each note in a list of notes one after another with specified times between them. The notes should be a list of MIDI numbers, symbols such as :E4 or chords such as chord(:A3, :major) - identical to the first parameter of the play function. The times should be a list of times between the notes in beats.

If the list of times is smaller than the number of gaps between notes, the list is repeated again. If the list of times is longer than the number of gaps between notes, then some of the times are ignored. See examples for more detail.

Accepts optional args for modification of the synth being played. See each synth's documentation for synth-specific opts. See `use_synth` and `with_synth` for changing the current synth.",
          args:          [[:notes, :list], [:times, :list_or_number]],
          opts:          DEFAULT_PLAY_OPTS,
          accepts_block: false,
          examples:      ["
play_pattern_timed [40, 42, 44, 46], [1, 2, 3]

# same as:

play 40
sleep 1
play 42
sleep 2
play 44
sleep 3
play 46",

        "play_pattern_timed [40, 42, 44, 46, 49], [1, 0.5]

# same as:

play 40
sleep 1
play 42
sleep 0.5
play 44
sleep 1
play 46
sleep 0.5
play 49",

        "play_pattern_timed [40, 42, 44, 46], [0.5]

# same as:

play 40
sleep 0.5
play 42
sleep 0.5
play 44
sleep 0.5
play 46",

        "play_pattern_timed [40, 42, 44], [1, 2, 3, 4, 5]

#same as:

play 40
sleep 1
play 42
sleep 2
play 44"]




      def play_chord(notes, *args)
        raise "play_chord expects a list of notes such as [70, 75, 82], got #{notes.inspect}" unless is_list_like?(notes)
        args_h = resolve_synth_opts_hash_or_array(args)
        shifted_notes = notes.map {|n| normalise_transpose_and_tune_note_from_args(n, args_h)}

        synth_name = current_synth_name
        trigger_chord(synth_name, shifted_notes, args_h)
      end
      doc name:          :play_chord,
          introduced:    Version.new(2,0,0),
          summary:       "Play notes simultaneously",
          doc:           "Play a list of notes at the same time.

Accepts optional args for modification of the synth being played. See each synth's documentation for synth-specific opts. See `use_synth` and `with_synth` for changing the current synth.",
          args:          [[:notes, :list]],
          opts:          DEFAULT_PLAY_OPTS,
          accepts_block: false,
          examples:      ["
play_chord [40, 45, 47]

# same as:

play 40
play 45
play 47",

        "play_chord [40, 45, 47], amp: 0.5

# same as:

play 40, amp: 0.5
play 45, amp: 0.5
play 47, amp: 0.5",

        "play_chord chord(:e3, :minor)"]




      def use_merged_synth_defaults(*args, &block)
        raise "use_merged_synth_defaults does not work with a block. Perhaps you meant with_merged_synth_defaults" if block
        current_defs = __thread_locals.get(:sonic_pi_mod_sound_synth_defaults)
        args_h = resolve_synth_opts_hash_or_array(args)
        merged_defs = (current_defs || {}).merge(args_h)
        __thread_locals.set :sonic_pi_mod_sound_synth_defaults, SonicPi::Core::SPMap.new(merged_defs)
      end
      doc name:          :use_merged_synth_defaults,
          introduced:    Version.new(2,0,0),
          summary:       "Merge synth defaults",
          doc:           "Specify synth arg values to be used by any following call to play. Merges the specified values with any previous defaults, rather than replacing them.",
          args:          [],
          opts:          {},
          accepts_block: false,
          examples:      ["
play 50 #=> Plays note 50

use_merged_synth_defaults amp: 0.5
play 50 #=> Plays note 50 with amp 0.5

use_merged_synth_defaults cutoff: 80
play 50 #=> Plays note 50 with amp 0.5 and cutoff 80

use_merged_synth_defaults amp: 0.7
play 50 #=> Plays note 50 with amp 0.7 and cutoff 80
",

        "use_synth_defaults amp: 0.5, cutoff: 80, pan: -1
use_merged_synth_defaults amp: 0.7
play 50 #=> Plays note 50 with amp 0.7, cutoff 80 and pan -1"]





      def with_merged_synth_defaults(*args, &block)
        raise "with_merged_synth_defaults must be called with a do/end block" unless block
        current_defs = __thread_locals.get(:sonic_pi_mod_sound_synth_defaults)

        args_h = resolve_synth_opts_hash_or_array(args)
        merged_defs = (current_defs || {}).merge(args_h)
        __thread_locals.set :sonic_pi_mod_sound_synth_defaults, SonicPi::Core::SPMap.new(merged_defs)
        res = block.call
        __thread_locals.set :sonic_pi_mod_sound_synth_defaults, current_defs
        res
      end
      doc name:           :with_merged_synth_defaults,
          introduced:     Version.new(2,0,0),
          summary:        "Block-level merge synth defaults",
          doc:            "Specify synth arg values to be used by any following call to play within the specified `do`/`end` block. Merges the specified values with any previous synth defaults, rather than replacing them. After the `do`/`end` block has completed, previous defaults (if any) are restored.",
          args:           [],
          opts:           {},
          accepts_block:  true,
          requires_block: true,
          examples:       ["
with_merged_synth_defaults amp: 0.5, pan: 1 do
  play 50 # => plays note 50 with amp 0.5 and pan 1
end",

        "play 50 #=> plays note 50
with_merged_synth_defaults amp: 0.5 do
  play 50 #=> plays note 50 with amp 0.5

  with_merged_synth_defaults pan: -1 do
    with_merged_synth_defaults amp: 0.7 do
      play 50 #=> plays note 50 with amp 0.7 and pan -1
    end
  end
  play 50 #=> plays note 50 with amp 0.5
end"]




      def use_synth_defaults(*args, &block)
        raise "use_synth_defaults does not work with a block. Perhaps you meant with_synth_defaults" if block
        args_h = resolve_synth_opts_hash_or_array(args)
        __thread_locals.set :sonic_pi_mod_sound_synth_defaults, SonicPi::Core::SPMap.new(args_h)
      end
      doc name:          :use_synth_defaults,
          introduced:    Version.new(2,0,0),
          summary:       "Use new synth defaults",
          doc:           "Specify new default values to be used by all subsequent calls to `play`. Will remove and override any previous defaults.",
          args:          [],
          opts:          {},
          accepts_block: false,
          examples:      ["
play 50 # plays note 50 with default arguments

use_synth_defaults amp: 0.5, cutoff: 70

play 50 # plays note 50 with an amp of 0.5, cutoff of 70 and defaults for rest of args

use_synth_defaults cutoff: 90

play 50 # plays note 50 with a cutoff of 90 and defaults for rest of args - note that amp is no longer 0.5
"]




      def use_sample_defaults(*args, &block)
        raise "use_sample_defaults does not work with a block. Perhaps you meant with_sample_defaults" if block
        args_h = resolve_synth_opts_hash_or_array(args)
        __thread_locals.set :sonic_pi_mod_sound_sample_defaults, SonicPi::Core::SPMap.new(args_h)
      end
      doc name:          :use_sample_defaults,
          introduced:    Version.new(2,5,0),
          summary:       "Use new sample defaults",
          doc:           "Specify new default values to be used by all subsequent calls to `sample`. Will remove and override any previous defaults.",
          args:          [],
          opts:          {},
          accepts_block: false,
          examples:      ["
sample :loop_amen # plays amen break with default arguments

use_sample_defaults amp: 0.5, cutoff: 70

sample :loop_amen # plays amen break with an amp of 0.5, cutoff of 70 and defaults for rest of args

use_sample_defaults cutoff: 90

sample :loop_amen  # plays amen break with a cutoff of 90 and defaults for rest of args - note that amp is no longer 0.5
"]


      def use_merged_sample_defaults(*args, &block)
        raise "use_merged_sample_defaults does not work with a block. Perhaps you meant with_merged_sample_defaults" if block
        current_defs = __thread_locals.get(:sonic_pi_mod_sound_sample_defaults)
        args_h = resolve_synth_opts_hash_or_array(args)
        merged_defs = (current_defs || {}).merge(args_h)
        __thread_locals.set :sonic_pi_mod_sound_sample_defaults, SonicPi::Core::SPMap.new(merged_defs)
      end
      doc name:          :use_merged_sample_defaults,
          introduced:    Version.new(2,9,0),
          summary:       "Merge new sample defaults",
          doc:           "Specify new default values to be used by all subsequent calls to `sample`. Merges the specified values with any previous defaults, rather than replacing them.",
          args:          [],
          opts:          {},
          accepts_block: false,
          examples:      ["
sample :loop_amen # plays amen break with default arguments

use_merged_sample_defaults amp: 0.5, cutoff: 70

sample :loop_amen # plays amen break with an amp of 0.5, cutoff of 70 and defaults for rest of args

use_merged_sample_defaults cutoff: 90

sample :loop_amen  # plays amen break with a cutoff of 90 and and an amp of 0.5 with defaults for rest of args
"]





      def with_sample_defaults(*args, &block)
        raise "with_sample_defaults must be called with a do/end block. Perhaps you meant use_sample_defaults" unless block
        current_defs = __thread_locals.get(:sonic_pi_mod_sound_sample_defaults)
        args_h = resolve_synth_opts_hash_or_array(args)
        __thread_locals.set :sonic_pi_mod_sound_sample_defaults, SonicPi::Core::SPMap.new(args_h)
        res = block.call
        __thread_locals.set :sonic_pi_mod_sound_sample_defaults, current_defs
        res
      end
      doc name:           :with_sample_defaults,
          introduced:     Version.new(2,5,0),
          summary:        "Block-level use new sample defaults",
          doc:            "Specify new default values to be used by all subsequent calls to `sample` within the `do`/`end` block. After the `do`/`end` block has completed, the previous sampled defaults (if any) are restored. For the contents of the block, will remove and override any previous defaults.",
          args:           [],
          opts:           {},
          accepts_block:  false,
          requires_block: false,
          examples:       ["
sample :loop_amen # plays amen break with default arguments

use_sample_defaults amp: 0.5, cutoff: 70

sample :loop_amen # plays amen break with an amp of 0.5, cutoff of 70 and defaults for rest of args

with_sample_defaults cutoff: 90 do
  sample :loop_amen  # plays amen break with a cutoff of 90 and defaults for rest of args - note that amp is no longer 0.5
end

sample :loop_amen  # plays amen break with a cutoff of 70 and amp is 0.5 again as the previous defaults are restored."]




      def with_merged_sample_defaults(*args, &block)
        raise "with_merged_sample_defaults must be called with a do/end block. Perhaps you meant use_merged_sample_defaults" unless block
        current_defs = __thread_locals.get(:sonic_pi_mod_sound_sample_defaults)
        args_h = resolve_synth_opts_hash_or_array(args)
        merged_defs = (current_defs || {}).merge(args_h)
        __thread_locals.set :sonic_pi_mod_sound_sample_defaults, SonicPi::Core::SPMap.new(merged_defs)
        res = block.call
        __thread_locals.set :sonic_pi_mod_sound_sample_defaults, current_defs
        res
      end
      doc name:           :with_merged_sample_defaults,
          introduced:     Version.new(2,9,0),
          summary:        "Block-level use merged sample defaults",
          doc:            "Specify new default values to be used by all subsequent calls to `sample` within the `do`/`end` block.  Merges the specified values with any previous sample defaults, rather than replacing them. After the `do`/`end` block has completed, the previous sampled defaults (if any) are restored.",
          args:           [],
          opts:           {},
          accepts_block:  false,
          requires_block: false,
          examples:       ["
sample :loop_amen # plays amen break with default arguments

use_merged_sample_defaults amp: 0.5, cutoff: 70

sample :loop_amen # plays amen break with an amp of 0.5, cutoff of 70 and defaults for rest of args

with_merged_sample_defaults cutoff: 90 do
  sample :loop_amen  # plays amen break with a cutoff of 90 and amp of 0.5
end

sample :loop_amen  # plays amen break with a cutoff of 70 and amp is 0.5 again as the previous defaults are restored."]




      def with_synth_defaults(*args, &block)
        raise "with_synth_defaults must be called with a do/end block" unless block
        current_defs = __thread_locals.get(:sonic_pi_mod_sound_synth_defaults)

        args_h = resolve_synth_opts_hash_or_array(args)
        __thread_locals.set :sonic_pi_mod_sound_synth_defaults, SonicPi::Core::SPMap.new(args_h)
        res = block.call
        __thread_locals.set :sonic_pi_mod_sound_synth_defaults, current_defs
        res
      end
      doc name:           :with_synth_defaults,
          introduced:     Version.new(2,0,0),
          summary:        "Block-level use new synth defaults",
          doc:            "Specify new default values to be used by all calls to `play` within the `do`/`end` block. After the `do`/`end` block has completed the previous synth defaults (if any) are restored.",
          args:           [],
          opts:           {},
          accepts_block:  true,
          requires_block: true,
          examples:       ["
play 50 # plays note 50 with default arguments

use_synth_defaults amp: 0.5, pan: -1

play 50 # plays note 50 with an amp of 0.5, pan of -1 and defaults for rest of args

with_synth_defaults amp: 0.6, cutoff: 80 do
  play 50 # plays note 50 with an amp of 0.6, cutoff of 80 and defaults for rest of args (including pan)
end

play 60 # plays note 60 with an amp of 0.5, pan of -1 and defaults for rest of args
"]




      def use_fx(*args, &block)
        raise "use_fx isn't supported in this version of Sonic Pi. Perhaps you meant with_fx"
      end




      def with_afx(fx_name, *args, &block)
        in_thread do
          with_fx(fx_name, *args, &block)
        end
      end




      def with_fx(fx_name, *args, &block)
        raise "with_fx must be called with a do/end block" unless block
        raise "with_fx block must only accept 0 or 1 args" unless [0, 1].include?(block.arity)

        ## Munge args
        args_h = resolve_synth_opts_hash_or_array(args)
        args_h[:reps] = 1 unless args_h[:reps]

        ## Teach with_fx to do nothing if fx_name is :none
        if fx_name == :none || !should_trigger?(args_h)
          if block.arity == 0
            return args_h[:reps].times do
              block.call
            end
          else
            bn = BlankNode.new(args_h)
            return args_h[:reps].times do
              block.call(bn)
            end
          end
        end

        # Determine the scsynth name for the FX.
        # If the FX is built-in then there will be info available - and the
        # FX name should be prepended with fx_
        #
        # If the FX is external (and we have explicitly allowed the use of
        # external FX), then just use the name the user specified
        fx_synth_name = "fx_#{fx_name}"
        info = Synths::SynthInfo.get_info(fx_synth_name)
        unless info
          raise "Unknown FX #{fx_name.inspect}" unless __thread_locals.get(:sonic_pi_mod_sound_use_external_synths)
          fx_synth_name = fx_name
        end

        resolve_buffer_args!(args_h, info) if info

        tracker = SynthTracker.new
        orig_tracker = __system_thread_locals.get(:sonic_pi_local_mod_fx_tracker)

        external_fx_t = Thread.current
        gc_init_completed = Promise.new
        fx_t_completed = Promise.new


        # These will be assigned later...
        fx_synth = nil
        new_bus = nil
        fx_container_group = nil
        fx_synth_group = nil
        block_res = nil
        block_exception = nil

        __no_kill_block do

          ## We're in a no_kill block, so the user can't randomly kill
          ## the current thread. That means it's safe to set up the
          ## synth trackers, create the fx synth and busses and modify
          ## the thread local to make sure new synth triggers in this
          ## thread output to this fx synth. We can also create a gc
          ## thread to wait for the current thread to either exit
          ## correctly or to die and to handle things appropriately.


          ## Create a new bus for this fx chain
          begin
            new_bus = @mod_sound_studio.new_fx_bus
          rescue AllocationError
            new_bus = nil
          end

          if new_bus
            args_h["in_bus"] = new_bus

            # Create new group for this FX - this is to enable the FX to be triggered at logical time
            # whilst ensuring it is in the correct position in the scsynth node tree.
            fx_container_group = @mod_sound_studio.new_group(:tail, current_group, "Run-#{current_job_id}-#{fx_name}")
            fx_synth_group = @mod_sound_studio.new_group(:head, fx_container_group, "Run-#{current_job_id}-#{fx_name}-synths")

            ## Create a 'GC' thread to safely handle completion of the FX
            ## block (or the case that the thread dies) and to clean up
            ## everything appropriately (i.e. ensure the FX synth has
            ## been killed).
            Thread.new do
              __system_thread_locals.set(:sonic_pi_local_thread_group, :gc)
              Thread.current.priority = -10
              ## Need to block until either the thread died (which will be
              ## if the job was stopped whilst this fx block was being
              ## executed or if the fx block has completed.
              fx_completed = Promise.new
              subthreads = nil
              t1 = Thread.new do
                __system_thread_locals.set(:sonic_pi_local_thread_group, :gc_parent_join)
                Thread.current.priority = -10
                external_fx_t.join

                # just grab all the subthreads - they're likely to be nuked anyway
                subthreads = __system_thread_locals(external_fx_t).get(:sonic_pi_local_spider_subthreads)
                ## Parent thread died - user must have stopped
                fx_completed.deliver! :thread_joined, false
              end

              t2 = Thread.new do
                __system_thread_locals.set(:sonic_pi_local_thread_group, :gc_fx_block_join)
                Thread.current.priority = -10
                subthreads = fx_t_completed.get
                ## FX block completed
                fx_completed.deliver! :fx_block_completed, false
              end

              ## Block!
              fx_completed.get
              ## Clean up blocking alert threads (one of them already
              ## completed, but kill both for completeness)
              t1.kill
              t2.kill

              Thread.new do
                __system_thread_locals.set(:sonic_pi_local_thread_group, :gc_kill_fx_synth)
                Thread.current.priority = -10
                if info
                  kill_delay = args_h[:kill_delay] || info.kill_delay(args_h) || 1
                else
                  kill_delay = args_h[:kill_delay] || 1
                end
                subthreads.each do |st|
                  join_thread_and_subthreads(st)
                end
                tracker.block_until_finished
                Kernel.sleep(kill_delay)
                fx_container_group.kill(true)
              end

              gc_init_completed.deliver! true
            end ## end gc collection thread definition

          end
        end


        # We couldn't create the bus so treat as if the FX was :none
        unless new_bus
          __delayed_serious_warning "All busses allocated - unable to honour FX"
          if block.arity == 0
            return args_h[:reps].times do
              block.call
            end
          else
            bn = BlankNode.new(args_h)
            return args_h[:reps].times do
              block.call(bn)
            end
          end
        end


        ## Trigger new fx synth (placing it in the fx group) and
        ## piping the in and out busses correctly
        if info
          use_logical_clock = info.trigger_with_logical_clock?
          t_minus_delta = use_logical_clock == :t_minus_delta
        else
          t_minus_delta = true
          use_logical_clock = true
        end
        fx_synth = trigger_fx(fx_synth_name, args_h, info, new_bus, fx_container_group, !use_logical_clock, t_minus_delta)

        ## Now actually execute the fx block. Pass the fx synth in as a
        ## parameter if the block was defined with a param.

        orig_subthreads = __system_thread_locals.get(:sonic_pi_local_spider_subthreads).to_a.clone
        orig_out_bus = current_out_bus
        orig_synth_group = current_group

        __system_thread_locals.set(:sonic_pi_mod_sound_job_group, fx_synth_group)
        __system_thread_locals.set(:sonic_pi_mod_sound_synth_out_bus, new_bus)
        __system_thread_locals.set_local(:sonic_pi_local_mod_fx_tracker, tracker)

        begin
          if block.arity == 0
            args_h[:reps].times do
              block_res = block.call
            end
          else
            args_h[:reps].times do
              block_res = block.call(fx_synth)
            end
          end
        rescue => e
          block_exception = e
        ensure
          subthreads = __system_thread_locals.get(:sonic_pi_local_spider_subthreads).to_a - orig_subthreads
          fx_t_completed.deliver! subthreads
          ## Reset out bus to value prior to this with_fx block
          __system_thread_locals.set(:sonic_pi_mod_sound_job_group, orig_synth_group)
          __system_thread_locals.set(:sonic_pi_mod_sound_synth_out_bus, orig_out_bus)
          __system_thread_locals.set_local(:sonic_pi_local_mod_fx_tracker, orig_tracker)
        end


        raise block_exception if block_exception

        # Wait for gc thread to complete. Once the gc thread has
        # completed, the tracker has been successfully removed, and all
        # the block threads have been determined. The gc thread has
        # spawned a new thread joining on those and waiting for all
        # remaining synths to complete and can be left to work in the
        # background...
        gc_init_completed.get

        # return result of block
        block_res
      end
      doc name:           :with_fx,
          introduced:     Version.new(2,0,0),
          summary:        "Use Studio FX",
          doc:            "This applies the named effect (FX) to everything within a given `do`/`end` block. Effects may take extra parameters to modify their behaviour. See FX help for parameter details.

For advanced control, it is also possible to modify the parameters of an effect within the body of the block. If you define the block with a single argument, the argument becomes a reference to the current effect and can be used to control its parameters (see examples).",
          args:           [[:fx_name, :symbol]],
          opts:           {reps: "Number of times to repeat the block in an iteration.",
          kill_delay:     "Amount of time to wait after all synths triggered by the block have completed before stopping and freeing the effect synthesiser." },
          accepts_block:  true,
          requires_block: true,
          intro_fn:       true,
          examples:      ["
# Basic usage
with_fx :distortion do # Use the distortion effect with default parameters
  play 50 # => plays note 50 with distortion
  sleep 1
  sample :loop_amen # => plays the loop_amen sample with distortion too
end",


        "# Specify effect parameters
with_fx :level, amp: 0.3 do # Use the level effect with the amp parameter set to 0.3
  play 50
  sleep 1
  sample :loop_amen
end",

        "
# Controlling the effect parameters within the block
with_fx :reverb, mix: 0.1 do |fx|
  # here we set the reverb level quite low to start with (0.1)
  # and we can change it later by using the 'fx' reference we've set up

  play 60 # plays note 60 with a little bit of reverb
  sleep 2

  control fx, mix: 0.5 # change the parameters of the effect to add more reverb
  play 60 # again note 60 but with more reverb
  sleep 2

  control fx, mix: 1 # change the parameters of the effect to add more reverb
  play 60 # plays note 60 with loads of reverb
  sleep 2
end",

        "
# Repeat the block 16 times internally
with_fx :reverb, reps: 16 do
  play (scale :e3, :minor_pentatonic), release: 0.1
  sleep 0.125
end

# The above is a shorthand for this:
with_fx :reverb do
  16.times do
    play (scale :e3, :minor_pentatonic), release: 0.1
    sleep 0.125
  end
end
"
      ]



      def current_synth
        current_synth_name
      end
      doc name:          :current_synth,
          introduced:    Version.new(2,0,0),
          summary:       "Get current synth",
          doc:           "Returns the current synth name.

This can be set via the fns `use_synth` and `with_synth`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
puts current_synth # Print out the current synth name"]




      def current_synth_defaults
        __thread_locals.get(:sonic_pi_mod_sound_synth_defaults)
      end
      doc name:          :current_synth_defaults,
          introduced:    Version.new(2,0,0),
          summary:       "Get current synth defaults",
          doc:           "Returns the current synth defaults. This is a map of synth arg names to values.

This can be set via the fns `use_synth_defaults`, `with_synth_defaults`, `use_merged_synth_defaults` and `with_merged_synth_defaults`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
use_synth_defaults amp: 0.5, cutoff: 80
play 50 # Plays note 50 with amp 0.5 and cutoff 80
puts current_synth_defaults #=> Prints {amp: 0.5, cutoff: 80}"]




      def current_sample_defaults
        __thread_locals.get(:sonic_pi_mod_sound_sample_defaults)
      end
      doc name:          :current_sample_defaults,
          introduced:    Version.new(2,5,0),
          summary:       "Get current sample defaults",
          doc:           "Returns the current sample defaults. This is a map of synth arg names to either values or functions.

This can be set via the fns `use_sample_defaults`, `with_sample_defaults`, `use_merged_sample_defaults` and `with_merged_sample_defaults`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
use_sample_defaults amp: 0.5, cutoff: 80
sample :loop_amen # Plays amen break with amp 0.5 and cutoff 80
puts current_sample_defaults #=> Prints {amp: 0.5, cutoff: 80}"]









      def current_volume
        @mod_sound_studio.volume
      end
      doc name:          :current_volume,
          introduced:    Version.new(2,0,0),
          summary:       "Get current volume",
          doc:           "Returns the current volume.

This can be set via the fn `set_volume!`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
puts current_volume # Print out the current volume",
        "set_volume! 2
puts current_volume #=> 2"]




      def current_transpose
        __thread_locals.get(:sonic_pi_mod_sound_transpose) || 0
      end
      doc name:          :current_transpose,
          introduced:    Version.new(2,0,0),
          summary:       "Get current transposition",
          doc:           "Returns the current transpose value.

This can be set via the fns `use_transpose` and `with_transpose`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
puts current_transpose # Print out the current transpose value"]




      def current_cent_tuning
        __thread_locals.get(:sonic_pi_mod_sound_cent_tuning) || 0
      end
      doc name:          :current_cent_tuning,
          introduced:    Version.new(2,9,0),
          summary:       "Get current cent shift",
          doc:           "Returns the cent shift value.

This can be set via the fns `use_cent_tuning` and `with_cent_tuning`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
puts current_cent_tuning # Print out the current cent shift"]




      def current_octave
        __thread_locals.get(:sonic_pi_mod_sound_octave_shift) || 0
      end
      doc name:          :current_octave,
          introduced:    Version.new(2,9,0),
          summary:       "Get current octave shift",
          doc:           "Returns the octave shift value.

This can be set via the fns `use_octave` and `with_octave`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
puts current_octave # Print out the current octave shift"]



      def current_debug
        __thread_locals.get(:sonic_pi_mod_sound_synth_silent)
      end
      doc name:          :current_debug,
          introduced:    Version.new(2,0,0),
          summary:       "Get current debug status",
          doc:           "Returns the current debug setting (`true` or `false`).

This can be set via the fns `use_debug` and `with_debug`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
puts current_debug # Print out the current debug setting"]




      def current_arg_checks
        __thread_locals.get(:sonic_pi_mod_sound_check_synth_args)
      end
      doc name:          :current_arg_checks,
          introduced:    Version.new(2,0,0),
          summary:       "Get current arg checking status",
          doc:           "Returns the current arg checking setting (`true` or `false`).

This can be set via the fns `use_arg_checks` and `with_arg_checks`.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
puts current_arg_checks # Print out the current arg check setting"]




      def set_volume!(vol, now=false, silent=false)
        max_vol = 5
        if (vol > max_vol)
          new_vol = max_vol
        elsif (vol < 0)
          new_vol = 0
        else
          new_vol = vol
        end
        @mod_sound_studio.set_volume new_vol, now, silent
      end
      doc name:          :set_volume!,
          introduced:    Version.new(2,0,0),
          summary:       "Set Volume globally",
          doc:           "Set the main system volume to `vol`. Accepts a value between `0` and `5` inclusive. Vols greater or smaller than the allowed values are trimmed to keep them within range. Default is `1`.",
          args:          [[:vol, :number]],
          opts:          nil,
          accepts_block: false,
          modifies_env: true,
          examples:      ["
set_volume! 2 # Set the main system volume to 2",

        "set_volume! -1 # Out of range, so sets main system volume to 0",

        "set_volume! 7 # Out of range, so sets main system volume to 5"
      ]




      def sample_loaded?(*args)
        filts_and_sources, _ = sample_split_filts_and_opts(args)
        path = resolve_sample_path(filts_and_sources)

        path = File.expand_path(path)
        return @mod_sound_studio.sample_loaded?(path)
      end

      doc name:          :sample_loaded?,
          introduced:    Version.new(2,2,0),
          summary:       "Test if sample was pre-loaded",
          doc:           "Given a path to a `.wav`, `.wave`, `.aif`, `.aiff` or `.flac` file, returns `true` if the sample has already been loaded.",
          args:          [[:path, :string]],
          opts:          nil,
          accepts_block: false,
          examples:      ["
load_sample :elec_blip # :elec_blip is now loaded and ready to play as a sample
puts sample_loaded? :elec_blip # prints true because it has been pre-loaded
puts sample_loaded? :misc_burp # prints false because it has not been loaded"]


      def load_sample(*args)
        filts_and_sources, _ = sample_split_filts_and_opts(args)
        path = sample_find_candidates(filts_and_sources)[0]
        load_sample_at_path path
      end
      doc name:          :load_sample,
          introduced:    Version.new(2,0,0),
          summary:       "Pre-load first matching sample",
          doc:           "Given a path to a `.wav`, `.wave`, `.aif`, `.aiff` or `.flac` file, pre-loads the sample into memory.

You may also specify the same set of source and filter pre-args available to `sample` itself. `load_sample` will then load all matching samples. See `sample`'s docs for more information." ,
          args:          [[:path, :string]],
          opts:          nil,
          accepts_block: false,
          examples:      ["
load_sample :elec_blip # :elec_blip is now loaded and ready to play as a sample
sample :elec_blip # No delay takes place when attempting to trigger it",

"# Using source and filter pre-args
dir = \"/path/to/sample/dir\"
load_sample dir # loads first matching sample in \"/path/to/sample/dir\"
load_sample dir, 1 # loads sample with index 1 in \"/path/to/sample/dir\"
load_sample dir, :foo # loads sample with name \"foo\" in \"/path/to/sample/dir\"
load_sample dir, \"quux\" # loads first sample with file name containing \"quux\" in \"/path/to/sample/dir\"
load_sample dir, /[Bb]ar/ # loads first sample which matches regex /[Bb]ar/ in \"/path/to/sample/dir\"
"      ]


      def load_samples(*args)
        filts_and_sources, _ = sample_split_filts_and_opts(args)
        paths = sample_find_candidates(filts_and_sources)
        paths.map do |p|
          load_sample_at_path p
        end
      end
      doc name:          :load_samples,
          introduced:    Version.new(2,0,0),
          summary:       "Pre-load all matching samples",
          doc:           "Given a directory containing multiple `.wav`, `.wave`, `.aif`, `.aiff` or `.flac` files, pre-loads all the samples into memory.

 You may also specify the same set of source and filter pre-args available to `sample` itself. `load_sample` will load all matching samples (not just the sample `sample` would play given the same opts) - see `sample`'s docs for more information." ,
          args:          [[:paths, :list]],
          opts:          nil,
          accepts_block: false,
          examples:      ["
 load_sample :elec_blip # :elec_blip is now loaded and ready to play as a sample
 sample :elec_blip # No delay takes place when attempting to trigger it",

 "# Using source and filter pre-args
 dir = \"/path/to/sample/dir\"
 load_sample dir # loads all samples in \"/path/to/sample/dir\"
 load_sample dir, 1 # loads sample with index 1 in \"/path/to/sample/dir\"
 load_sample dir, :foo # loads sample with name \"foo\" in \"/path/to/sample/dir\"
 load_sample dir, \"quux\" # loads all samples with file names containing \"quux\" in \"/path/to/sample/dir\"
 load_sample dir, /[Bb]ar/ # loads all samples which match regex /[Bb]ar/ in \"/path/to/sample/dir\"

 "]






      def load_sample_at_path(path)
        case path
        when String
          raise "Attempted to load sample with an empty string as path" if path.empty?
          path = File.expand_path(path)
          info, cached = @mod_sound_studio.load_sample(path)
          __info "Loaded sample #{unify_tilde_dir(path).inspect}" unless cached
          return info
        else
          raise "Unknown sample description: #{path.inspect}\n expected a string containing a path."
        end
      end




      def sample_info(*args)
        sample_buffer(*args)
      end
      doc name:          :sample_info,
          introduced:    Version.new(2,0,0),
          summary:       "Get sample information",
          doc:           "Alias for the `load_sample` method. Loads sample if necessary and returns sample information.",
          args:          [[:path, :string]],
          opts:          nil,
          accepts_block: false,
          examples:      ["see load_sample"]




      def sample_buffer(*args)
        filts_and_sources, _ = sample_split_filts_and_opts(args)
        path = resolve_sample_path(filts_and_sources)
        load_sample_at_path(path)
      end
      doc name:          :sample_buffer,
          introduced:    Version.new(2,0,0),
          summary:       "Get sample data",
          doc:           "Alias for the `load_sample` method. Loads sample if necessary and returns buffer information.",
          args:          [[:path, :string]],
          opts:          nil,
          accepts_block: false,
          examples:      ["see load_sample"]


      def sample_duration(*args)
        filts_and_sources, args_a = sample_split_filts_and_opts(args)
        path = resolve_sample_path(filts_and_sources)
        dur = load_sample_at_path(path).duration
        args_h = merge_synth_arg_maps_array(args_a)

        normalise_and_resolve_sample_args(path, args_h, nil, true)

        start = args_h[:start] || 0
        start = [1, [0, start].max].min
        finish = args_h[:finish] || 1
        finish = [1, [0, finish].max].min
        rate = args_h[:rate] || 1

        if finish > start
          len = finish - start
        else
          len = start - finish
        end

        real_dur = dur * 1.0/(rate.abs) * len

        if args_h.has_key?(:sustain) && args_h[:sustain] != -1
          attack = [0,  (args_h[:attack]  ||args_h[:atk]).to_f].max
          decay = [0,   (args_h[:decay]   ||args_h[:dec]).to_f].max
          sustain = [0, (args_h[:sustain] ||args_h(:sus)).to_f].max
          release = [0, (args_h[:release] ||args_h[:rel]).to_f].max
          real_dur = [attack + decay + sustain + release, real_dur].min
        end

        if __thread_locals.get(:sonic_pi_spider_arg_bpm_scaling)
          return real_dur.to_f / __system_thread_locals.get(:sonic_pi_spider_sleep_mul)
        else
          return real_dur
        end
      end

      doc name:          :sample_duration,
          introduced:    Version.new(2,0,0),
          summary:       "Get duration of sample in beats",
          doc:           "Given the name of a loaded sample, or a path to a `.wav`, `.wave`, `.aif`, `.aiff` or `.flac` file returns the length of time in beats that the sample would play for. `sample_duration` understands and accounts for all the opts you can pass to `sample` which have an effect on the playback duration such as `rate:`. The time returned is scaled to the current BPM.

*Note:* avoid using `sample_duration` to set the sleep time in `live_loop`s, prefer stretching the sample with the `beat_stretch:` opt or changing the BPM instead. See the examples below for details.",
          args:          [[:path, :string]],
          opts:          {:rate    => "Rate modifier. For example, doubling the rate will halve the duration.",
                          :start   => "Start position of sample playback as a value from 0 to 1",
                          :finish  => "Finish position of sample playback as a value from 0 to 1",
                          :attack  => "Duration of the attack phase of the envelope.",
                          :decay   => "Duration of the decay phase of the envelope.",
                          :sustain => "Duration of the sustain phase of the envelope.",
                          :release => "Duration of the release phase of the envelope.",
                          :beat_stretch  => "Change the rate of the sample so that its new duration matches the specified number of beats.",
                          :pitch_stretch => "Change the rate of the sample so that its new duration matches the specified number of beats but attempt to preserve pitch.",
                          :rpitch        => "Change the rate to shift the pitch up or down the specified number of MIDI notes."},

          accepts_block: false,
          examples:      ["
# Simple use
puts sample_duration(:loop_garzul) # returns 8.0 because this sample is 8 seconds long
",

"
# The result is scaled to the current BPM
use_bpm 120
puts sample_duration(:loop_garzul) # => 16.0
use_bpm 90
puts sample_duration(:loop_garzul) # => 12.0
use_bpm 21
puts sample_duration(:loop_garzul) # => 2.8
",

"
# Avoid using sample_duration to set the sleep time in live_loops

live_loop :avoid_this do               # It is possible to use sample_duration to drive the frequency of a live loop.
  with_fx :slicer do                   # However, if you're using a rhythmical sample such as a drum beat and it isn't
    sample :loop_amen                  # in the same BPM as the current BPM, then the FX such as this slicer will be
    sleep sample_duration(:loop_amen)  # badly out of sync. This is because the slicer slices at the current BPM and
  end                                  # this live_loop is looping at a different BPM (that of the sample)
end

live_loop :prefer_this do              # Instead prefer to set the BPM of the live_loop to match the sample. It has
  use_sample_bpm :loop_amen            # two benefits. Now our sleep is a nice and simple 1 (as it's one beat).
  with_fx :slicer do                   # Also, our slicer now works with the beat and sounds much better.
    sample :loop_amen
    sleep 1
  end
end

live_loop :or_this do                  # Alternatively we can beat_stretch the sample to match the current BPM. This has the
  with_fx :slicer do                   # side effect of changing the rate of the sample (and hence the pitch). However, the
    sample :loop_amen, beat_stretch: 1 # FX works nicely in time and the sleep time is also a simple 1.
    sleep 1
  end
end
",

"
# The standard sample opts are also honoured

                                                                  # Playing a sample at standard speed will return standard length
sample_duration :loop_garzul, rate: 1                             # => 8.0

                                                                  # Playing a sample at half speed will double duration
sample_duration :loop_garzul, rate: 0.5                           # => 16.0

                                                                  # Playing a sample at double speed will halve duration
sample_duration :loop_garzul, rate: 2                             # => 4.0

                                                                  # Playing a sample backwards at double speed will halve duration
sample_duration :loop_garzul, rate: -2                            # => 4.0

                                                                  # Without an explicit sustain: opt attack: just affects amplitude not duration
sample_duration :loop_garzul, attack: 1                           # => 8.0
sample_duration :loop_garzul, attack: 100                         # => 8.0
sample_duration :loop_garzul, attack: 0                           # => 8.0

                                                                  # Without an explicit sustain: opt release: just affects amplitude not duration
sample_duration :loop_garzul, release: 1                          # => 8.0
sample_duration :loop_garzul, release: 100                        # => 8.0
sample_duration :loop_garzul, release: 0                          # => 8.0

                                                                  # Without an explicit sustain: opt decay: just affects amplitude not duration
sample_duration :loop_garzul, decay: 1                            # => 8.0
sample_duration :loop_garzul, decay: 100                          # => 8.0
sample_duration :loop_garzul, decay: 0                            # => 8.0

                                                                  # With an explicit sustain: opt, if the attack + decay + sustain + release envelope
                                                                  # duration is less than the sample duration time, the envelope will shorten the
                                                                  # sample time.
sample_duration :loop_garzul, sustain: 0, attack: 0.5             # => 0.5
sample_duration :loop_garzul, sustain: 0, decay: 0.1              # => 0.1
sample_duration :loop_garzul, sustain: 0, release: 1              # => 1.0
sample_duration :loop_garzul, sustain: 2, attack: 0.5, release: 1 # => 3.5

                                                                  # If the envelope duration is longer than the sample it will not affect the
                                                                  # sample duration
sample_duration :loop_garzul, sustain: 0, attack: 8, release: 3   # => 8


                                                                  # All other opts are taken into account before the comparison with the envelope opts.
sample_duration :loop_garzul, rate: 10                            # => 0.8
sample_duration :loop_garzul, sustain: 0, attack: 0.9, rate: 10   # => 0.8 (The duration of the sample is less than the envelope length so wins)


                                                                  # The rpitch: opt will modify the rate to shift the pitch of the sample up and down
                                                                  # and therefore affects duration.
sample_duration :loop_garzul, rpitch: 12                          # => 4.0
sample_duration :loop_garzul, rpitch: -12                         # => 16

                                                                  # The rpitch: and rate: opts combine together.
sample_duration :loop_garzul, rpitch: 12, rate: 2                 # => 2.0

                                                                  # The beat_stretch: opt stretches the sample so that its duration matches the value.
                                                                  # It also combines with rate:
sample_duration :loop_garzul, beat_stretch: 3                     # => 3.0
sample_duration :loop_garzul, beat_stretch: 3, rate: 0.5          # => 6.0

                                                                  # The pitch_stretch: opt acts identically to beat_stretch when just considering sample
                                                                  # duration.
sample_duration :loop_garzul, pitch_stretch: 3                    # => 3.0
sample_duration :loop_garzul, pitch_stretch: 3, rate: 0.5         # => 6.0

                                                                  # The start: and finish: opts can also shorten the sample duration and also combine
                                                                  # with other opts such as rate:
sample_duration :loop_garzul, start: 0.5                          # => 4.0
sample_duration :loop_garzul, start: 0.5, finish: 0.75            # => 2.0
sample_duration :loop_garzul, finish: 0.5, start: 0.75            # => 2.0
sample_duration :loop_garzul, rate: 2, finish: 0.5, start: 0.75 # => 1.0
",
"
# Triggering samples one after another

sample :loop_amen                    # start the :loop_amen sample
sleep sample_duration(:loop_amen)    # wait for the duration of :loop_amen before
sample :loop_amen                    # starting it again
"



      ]

      def sample_split_filts_and_opts(args)
        idx = args.find_index {|el| el.is_a?(Hash)}
        if idx
          filts_and_sources =  args[0...idx]
          opts = args[idx..-1]
        else
          filts_and_sources =  args
          opts = {}
        end

        filts_and_sources.map! do |f|
          if f.is_a? SampleBuffer
            f.path
          else
            f
          end
        end

        # remove any nils
        filts_and_sources.compact!

        return filts_and_sources, opts
      end

      def resolve_sample_paths(filts_and_sources)
        return filts_and_sources if filts_and_sources.size == 1 && filts_and_sources[0].is_a?(Buffer)
        sample_find_candidates(filts_and_sources)
      end

      def resolve_sample_path(filts_and_sources)
        resolve_sample_paths(filts_and_sources)[0]
      end




      def sample_paths(*args)
        filts_and_sources, _ = sample_split_filts_and_opts(args)
        resolve_sample_paths(filts_and_sources).ring
      end
      doc name:          :sample_paths,
          introduced:    Version.new(2,10,0),
          summary:       "Sample Pack Filter Resolution",
          doc:           "Accepts the same pre-args and opts as `sample` and returns a ring of matched sample paths.",
          args:          [[:pre_args, :source_and_filter_types]],
          returns:       :ring,
          opts:          nil,
          accepts_block: false,
          examples:      ["
sample_paths \"/path/to/samples/\" #=> ring of all top-level samples in /path/to/samples",
"
sample_paths \"/path/to/samples/**\" #=> ring of all nested samples in /path/to/samples",
"
sample_paths \"/path/to/samples/\", \"foo\" #=> ring of all samples in /path/to/samples
                                                containing the string \"foo\" in their filename."     ]




      def sample(*args, &blk)
        filts_and_sources, args_a = sample_split_filts_and_opts(args)
        args_h = merge_synth_arg_maps_array(args_a)
        tls = __thread_locals.get(:sonic_pi_mod_sound_sample_defaults) || {}

        args_h = tls.merge(args_h).to_h

        if filts_and_sources.size == 0
          if args_h.has_key?(:path)
            # handle case where sample receives only opts
            path = resolve_sample_path([args_h.delete(:path)])
          else
            __delayed_message "sample #{filts_and_sources.inspect}\n           - no match found, skipping."
            return BlankNode.new(args_h)
          end
        else
          path = resolve_sample_path(filts_and_sources)
        end

        if path == nil
          __delayed_message "sample #{filts_and_sources.inspect}\n           - no match found, skipping."
          return BlankNode.new(args_h)
        end

        path = unify_tilde_dir(path) if path.is_a? String

        # Combine thread local defaults here as
        # normalise_and_resolve_synth_args has only been taught about
        # synth thread local defaults

        if @mod_sound_studio.sample_loaded?(path)
          res_node = trigger_sampler path, args_h
        else
          res = Promise.new
          in_thread { res.deliver!(trigger_sampler path, args_h)}
          res_node = LazyNode.new(res)
        end

        if block_given?
          in_thread do
            blk.call(res_node)
          end
        end
        res_node
      end

      doc name:          :sample,
          introduced:    Version.new(2,0,0),
          summary:       "Trigger sample",
          doc:           "Play back a recorded sound file (sample). Sonic Pi comes with lots of great samples included (see the section under help) but you can also load and play `.wav`, `.wave`, `.aif`, `.aiff` or `.flac` files from anywhere on your computer too. To play a built-in sample use the corresponding keyword such as `sample :bd_haus`. To play any file on your computer use a full path such as `sample \"/path/to/sample.wav\"`.

There are many opts for manipulating the playback. For example, the `rate:` opt affects both the speed and the pitch of the playback. To control the rate of the sample in a pitch-meaningful way take a look at the `rpitch:` opt.

The sampler synth has three separate envelopes - one for amplitude, one for a low pass filter and another for a high pass filter. These work very similar to the standard synth envelopes except for two major differences. Firstly, the envelope times do not stretch or shrink to match the BPM. Secondly, the sustain time by default stretches to make the envelope fit the length of the sample. This is explained in detail in the tutorial.

Samples are loaded on-the-fly when first requested (and subsequently remembered). If the sample loading process takes longer than the schedule ahead time, the sample trigger will be skipped rather than be played late and out of time. To avoid this you may preload any samples you wish to work with using `load_sample` or `load_samples`.

It is possible to set the `start:` and `finish:` positions within the sample to play only a sub-section of it. These values can be automatically chosen based on an onset detection algorithm which will essentially isolate each individual drum or synth hit in the sample and let you access each one by an integer index (floats will be rounded to the nearest integer value). See the `onset:` docstring and examples for more information.

Finally, the sampler supports a powerful filtering system to make it easier to work with large folders of samples. The filter commands must be used before the first standard opt. There are six kinds of filter parameters you may use:

1. Folder strings - `\"/foo/bar\"` - which will add all samples within the folder to the set of candidates.
2. Recursive folder strings - `\"/foo/bar/**\"` - Folder strings ending with `**` will add all samples contained within all subfolders (searched recursively).
3. Sample strings - `\"/path/to/sample.wav\"` - which will add the specific sample to the set of candidates.
4. Other strings - `\"foobar\"` - which will filter the candidates based on whether the filename contains the string.
5. Regular expressions - `/b[aA]z.*/` - which will filter the candidates based on whether the regular expression matches the filename.
6. Keywords - `:quux` - will filter the candidates based on whether the keyword is a direct match of the filename (without extension).
7. Numbers - `0` - will select the candidate with that index (wrapping round like a ring if necessary).
8. Lists of the above - `[\"/foo/bar\", \"baz\", /0-9.*/]` - will recurse down and work through the internal filter parameters as if they were in the top level.
9. Lambdas - `lambda {|s| [s.choose] }` - the ultimate power tool for filters. Allows you to create a custom fn which receives a list of candidates as an arg and which should return a new list of candidates (this may be smaller, larger, re-ordered it's up to you).

By combining commands which add to the candidates and then filtering those candidates it is possible to work with folders full of samples in very powerful ways. Note that the specific ordering of filter parameters is irrelevant with the exception of the numbers - in which case the last number is the index. All the candidates will be gathered first before the filters are applied.
",

          args:          [[:name_or_path, :symbol_or_string]],
          opts:          {:rate          => "Rate with which to play back the sample. Higher rates mean an increase in pitch and a decrease in duration. Default is 1.",
                          :beat_stretch  => "Stretch (or shrink) the sample to last for exactly the specified number of beats. Please note - this does *not* keep the pitch constant and is essentially the same as modifying the rate directly.",
                          :pitch_stretch => "Stretch (or shrink) the sample to last for exactly the specified number of beats. This attempts to keep the pitch constant using the `pitch:` opt. Note, it's very likely you'll need to experiment with the `window_size:`, `pitch_dis:` and `time_dis:` opts depending on the sample and the amount you'd like to stretch/shrink from original size.",
                          :attack        => "Time to reach full volume. Default is 0.",
                          :sustain       => "Time to stay at full volume. Default is to stretch to length of sample (minus attack and release times).",
                          :release       => "Time (from the end of the sample) to go from full amplitude to 0. Default is 0.",
                          :start         => "Position in sample as a fraction between 0 and 1 to start playback. Default is 0.",
                          :finish        => "Position in sample as a fraction between 0 and 1 to end playback. Default is 1.",
                          :pan           => "Stereo position of audio. -1 is left ear only, 1 is right ear only, and values in between position the sound accordingly. Default is 0.",
                          :amp           => "Amplitude of playback.",
                          :pre_amp           => "Amplitude multiplier which takes place immediately before any internal FX such as the low pass filter, compressor or pitch modification. Use this opt if you want to overload the compressor.",
                          :onset         => "Analyse the sample with an onset detection algorithm and set the `start:` and `finish:` opts to play the nth onset only. Allows you to treat a rhythm sample as a palette of individual drum/synth hits. Floats are rounded to the nearest whole number.",
                          :slice         => "Divides the sample duration evenly into `num_slices` sections (defaults to 16) and set the `start:` and `finish:` opts to play the nth slice only. Use the envelope opts to remove any clicks introduced if the slice boundary is in the middle of a sound. Also consider `onset:`. Floats are rounded to the nearest whole number.",
                          :num_slices         => "Number of slices to divide the sample into when using the `slice:` opt. Defaults to 16. Floats are rounded to the nearest whole number.",
                          :norm              => "Normalise the audio (make quieter parts of the sample louder and louder parts quieter) - this is similar to the normaliser FX. This may emphasise any clicks caused by clipping.",
                          :lpf               => "Cutoff value of the built-in low pass filter (lpf) in MIDI notes. Unless specified, the lpf is *not* added to the signal chain.",
                          :lpf_init_level => "The initial low pass filter envelope value as a MIDI note. This envelope is bypassed if no lpf env opts are specified. Default value is to match the `lpf_min:` opt.",
                          :lpf_attack_level  => "The peak lpf cutoff (value of cutoff at peak of attack) as a MIDI note. Default value is to match the `lpf_decay_level:` opt.",
                          :lpf_decay_level   => "The level of lpf cutoff after the decay phase as a MIDI note. Default value is to match the `lpf_sustain_level:` opt.",
                          :lpf_sustain_level => "The sustain cutoff (value of lpf cutoff at sustain time) as a MIDI note. Default value is to match the `lpf_release_level:` opt.",
                          :lpf_release_level => "The final value of the low pass filter envelope as a MIDI note. This envelope is bypassed if no lpf env opts are specified. Default value is to match the `lpf:` opt.",
                          :lpf_attack        => "Attack time for lpf cutoff filter. Amount of time (in beats) for sound to reach full cutoff value. Default value is set to match amp envelope's attack value.",
                          :lpf_decay         => "Decay time for lpf cutoff filter. Amount of time (in beats) for sound to move from full cutoff value (cutoff attack level) to the cutoff sustain level. Default value is set to match amp envelope's decay value.",
                          :lpf_sustain       =>  "Amount of time for lpf cutoff value to remain at sustain level in beats. When -1 (the default) will auto-stretch.",
                          :lpf_release       => "Amount of time (in beats) for sound to move from lpf cutoff sustain value to lpf cutoff min value. Default value is set to match amp envelope's release value.",
                          :lpf_min           => "Starting value of the lpf cutoff envelope. Default is 30.",
                          :lpf_env_curve     => "Select the shape of the curve between levels in the lpf cutoff envelope. 1=linear, 2=exponential, 3=sine, 4=welch, 6=squared, 7=cubed.",
                          :hpf               => "Cutoff value of the built-in high pass filter (hpf) in MIDI notes. Unless specified, the hpf is *not* added to the signal chain.",
                          :hpf_init_level => "The initial high pass filter envelope value as a MIDI note. This envelope is bypassed if no hpf env opts are specified. Default value is set to 130.",
                          :hpf_attack_level  => "The peak hpf cutoff (value of cutoff at peak of attack) as a MIDI note. Default value is to match the `hpf_decay_level:` opt.",
                          :hpf_decay_level   => "The level of hpf cutoff after the decay phase as a MIDI note. Default value is to match the `hpf_sustain_level:` opt.",
                          :hpf_sustain_level => "The sustain cutoff (value of hpf cutoff at sustain time) as a MIDI note. Default value is to match the `hpf_release_level:` opt.",
                          :hpf_release_level => "The sustain hpf cutoff (value of hpf cutoff at sustain time) as a MIDI note. Default value is to match the `hpf:` opt.",
                          :hpf_attack        => "Attack time for hpf cutoff filter. Amount of time (in beats) for sound to reach full cutoff value. Default value is set to match amp envelope's attack value.",
                          :hpf_decay         => "Decay time for hpf cutoff filter. Amount of time (in beats) for sound to move from full cutoff value (cutoff attack level) to the cutoff sustain level. Default value is set to match amp envelope's decay value.",
                          :hpf_sustain       =>  "Amount of time for hpf cutoff value to remain at sustain level in beats. When -1 (the default) will auto-stretch.",
                          :hpf_release       => "Amount of time (in beats) for sound to move from hpf cutoff sustain value to hpf cutoff min value. Default value is set to match amp envelope's release value.",
                          :hpf_env_curve     => "Select the shape of the curve between levels in the hpf cutoff envelope. 1=linear, 2=exponential, 3=sine, 4=welch, 6=squared, 7=cubed.",
                          :hpf_max           => "Maximum value of the high pass filter envelope. Default is 200.",
                          :rpitch        => "Rate modified pitch. Multiplies the rate by the appropriate ratio to shift up or down the specified amount in MIDI notes. Please note - this does *not* keep the duration and rhythmical rate constant and is essentially the same as modifying the rate directly.",
                          :pitch         => "Pitch adjustment in semitones. 1 is up a semitone, 12 is up an octave, -12 is down an octave etc. Maximum upper limit of 24 (up 2 octaves). Lower limit of -72 (down 6 octaves). Decimal numbers can be used for fine tuning.",
                          :window_size   => "Pitch shift-specific opt - only honoured if the `pitch:` opt is used. Pitch shift works by chopping the input into tiny slices, then playing these slices at a higher or lower rate. If we make the slices small enough and overlap them, it sounds like the original sound with the pitch changed. The window_size is the length of the slices and is measured in seconds. It needs to be around 0.2 (200ms) or greater for pitched sounds like guitar or bass, and needs to be around 0.02 (20ms) or lower for percussive sounds like drum loops. You can experiment with this to get the best sound for your input.",
                          :pitch_dis     => "Pitch shift-specific opt - only honoured if the `pitch:` opt is used. Pitch dispersion - how much random variation in pitch to add. Using a low value like 0.001 can help to \"soften up\" the metallic sounds, especially on drum loops. To be really technical, pitch_dispersion is the maximum random deviation of the pitch from the pitch ratio (which is set by the `pitch:` opt).",
                          :time_dis      => "Pitch shift-specific opt - only honoured if the `pitch:` opt is used. Time dispersion - how much random delay before playing each grain (measured in seconds). Again, low values here like 0.001 can help to soften up metallic sounds introduced by the effect. Large values are also fun as they can make soundscapes and textures from the input, although you will most likely lose the rhythm of the original. NB - This won't have an effect if it's larger than window_size.",


                          :compress => "Enable the compressor. This sits at the end of the internal FX chain immediately before the `amp:` opt. Therefore to drive the compressor use the `pre_amp:` opt which will amplify the signal before it hits any internal FX. The compressor compresses the dynamic range of the incoming signal. Equivalent to automatically turning the amp down when the signal gets too loud and then back up again when it's quiet. Useful for ensuring the containing signal doesn't overwhelm other aspects of the sound. Also a general purpose hard-knee dynamic range processor which can be tuned via the opts to both expand and compress the signal.",

                          :threshold => "Threshold value determining the break point between slope_below and slope_above. Only valid if the compressor is enabled by turning on the `compress:` opt.",

                          :slope_below => "Slope of the amplitude curve below the threshold. A value of 1 means that the output of signals with amplitude below the threshold will be unaffected. Greater values will magnify and smaller values will attenuate the signal. Only valid if the compressor is enabled by turning on the `compress:` opt.",
                          :slope_above => "Slope of the amplitude curve above the threshold. A value of 1 means that the output of signals with amplitude above the threshold will be unaffected. Greater values will magnify and smaller values will attenuate the signal. Only valid if the compressor is enabled by turning on the `compress:` opt.",

                          :clamp_time => "Time taken for the amplitude adjustments to kick in fully (in seconds). This is usually pretty small (not much more than 10 milliseconds). Also known as the time of the attack phase. Only valid if the compressor is enabled by turning on the `compress:` opt.",

                          :relax_time => "Time taken for the amplitude adjustments to be released. Usually a little longer than clamp_time. If both times are too short, you can get some (possibly unwanted) artefacts. Also known as the time of the release phase. Only valid if the compressor is enabled by turning on the `compress:` opt.",


                          :slide      => "Default slide time in beats for all slide opts. Individually specified slide opts will override this value.",
                          :path       => "Path of the sample to play. Typically this opt is rarely used instead of the more powerful source/filter system. However it can be useful when working with pre-made opt maps."},
          accepts_block:  true,
          intro_fn:       true,
          examples:      ["
# Play a built-in sample
sample :loop_amen # Plays the Amen break",
        "
# Play two samples at the same time
# with incredible timing accuracy
sample :loop_amen
sample :ambi_lunar_land # Note, for timing guarantees select the pref:
                        #   Studio -> Synths and FX -> Enforce timing guarantees",
        "
# Create a simple repeating bass drum
live_loop :bass do
  sample :bd_haus
  sleep 0.5
end",
        "
# Create a more complex rhythm with multiple live loops:
live_loop :rhythm do
  sample :tabla_ghe3 if (spread 5, 7).tick
  sleep 0.125
end
live_loop :bd, sync: :rhythm do
  sample :bd_haus, lpf: 90, amp: 2
  sleep 0.5
end",
        "
# Change the playback speed of the sample using rate:
sample :loop_amen, rate: 0.5 # Play the Amen break at half speed
                             # for old school hip-hop",
        "
# Speed things up
sample :loop_amen, rate: 1.5 # Play the Amen break at 1.5x speed
                             # for a jungle/gabba sound",
        "
# Go backwards
sample :loop_amen, rate: -1 # Negative rates play the sample backwards",
        "
# Fast rewind
sample :loop_amen, rate: -3 # Play backwards at 3x speed for a fast rewind effect",
        "
# Start mid sample
sample :loop_amen, start: 0.5 # Start playback half way through",
        "
# Finish mid sample
sample :loop_amen, finish: 0.5 # Finish playback half way through",
        "
# Play part of a sample
sample :loop_amen, start: 0.125, finish: 0.25 # Play the second eighth of the sample",
        "
# Finishing before the start plays backwards
sample :loop_amen, start: 0.25, finish: 0.125 # Play the second eighth of the sample backwards",
        "
# Play a section of a sample at quarter speed backwards
sample :loop_amen, start: 0.125, finish: 0.25, rate: -0.25 # Play the second eighth of the
                                                           # amen break backwards at a
                                                           # quarter speed",
        "
# Control a sample synchronously
s = sample :loop_amen, lpf: 70
sleep 0.5
control s, lpf: 130
sleep 0.5
synth :dsaw, note: :e3 # This is triggered 1s from start",

" # Controlling a sample asynchronously
sample :loop_amen, lpf: 70 do |s|
  sleep 1                                # This block is run in an implicit in_thread
  control s, lpf: 130                    # and therefore is asynchronous
end
sleep 0.5
synth :dsaw, note: :e3 # This is triggered 0.5s from start",

        "
# Play with slices
sample :loop_garzul, slice: 0      # => play the first 16th of the sample
sleep 0.5
4.times do
  sample :loop_garzul, slice: 1    # => play the second 16th of the sample 4 times
  sleep 0.125
end
sample :loop_garzul, slice: 4, num_slices: 4, rate: -1      # => play the final quarter backwards
",
        "
# Build a simple beat slicer
use_sample_bpm :loop_amen                    # Set the BPM to match the amen break sample
live_loop :beat_slicer do
  n = 8                                      # Specify number of slices
                                             # (try changing to 2, 4, 6, 16 or 32)
  s = rand_i n                               # Choose a random slice within range
  sample :loop_amen, slice: s, num_slices: n # Play the specific part of the sample
  sleep 1.0/n                                # Sleep for the duration of the slice
end",
        "
# Play with the built-in low pass filter, high pass filter and compressor
sample :loop_amen, lpf: 80, hpf: 70, compress: 1, pre_amp: 10 # Make the amen break sound punchy.",
        "
# Use the cutoff filter envelopes
sample :loop_garzul, lpf_attack: 8 # Sweep the low pass filter up over 8 beats
sleep 8
sample :loop_garzul, hpf_attack: 8 # Sweep the high pass filter down over 8 beats",
        "
# Sample stretching
puts sample_duration :loop_industrial                   # => 0.88347
puts sample_duration :loop_industrial, beat_stretch: 1  # => 1
live_loop :industrial do
  sample :loop_industrial, beat_stretch: 1              # Stretch the sample to make it 1 beat long
  sleep 1                                               # This now loops perfectly.
                                                        # However, note that stretching/shrinking
                                                        # also modifies the pitch.
end",
        "
# Sample shrinking
puts sample_duration :loop_garzul                       # => 8
puts sample_duration :loop_garzul, beat_stretch: 6      # => 6
live_loop :garzul do
  sample :loop_garzul, beat_stretch: 6                  # As :loop_garzul is longer than 6 beats
                                                        # it is shrunk to fit. This increases the
                                                        # pitch.
  sleep 6
end",
        "
# Sample stretching matches the BPM
use_bpm 30                                              # Set the BPM to 30
puts sample_duration :loop_garzul                       # => 4.0 (at 30 BPM the sample lasts for 4 beats)
puts sample_duration :loop_garzul, beat_stretch: 6      # => 6.0
live_loop :garzul do
  sample :loop_garzul, beat_stretch: 6                  # The sample is stretched to match 6 beats at 30 BPM
  sleep 6
end",
        "
# External samples
sample \"/path/to/sample.wav\"                          # Play any Wav, Aif or FLAC sample on your computer
                                                        # by simply passing a string representing the full
                                                        # path",
        "
# Sample pack filtering
dir = \"/path/to/dir/of/samples\"                       # You can easily work with a directory of samples
sample dir                                              # Play the first sample in the directory
                                                        # (it is sorted alphabetically)
sample dir, 1                                           # Play the second sample in the directory
sample dir, 99                                          # Play the 100th sample in the directory, or if there
                                                        # are fewer, treat the directory like a ring and keep
                                                        # wrapping the index round until a sample is found.
                                                        # For example, if there are 90 samples, the 10th sample
                                                        # is played (index 9).
sample dir, \"120\"                                     # Play the first sample in the directory that contains
                                                        # the substring \"120\".
                                                        # For example, this may be \"beat1_120_rave.wav\"
sample dir, \"120\", 1                                  # Play the second sample in the directory that contains
                                                        # the substring \"120\".
                                                        # For example, this may be \"beat2_120_rave.wav\"
sample dir, /beat[0-9]/                                 # Play the first sample in the directory that matches
                                                        # the regular expression /beat[0-9]/.
                                                        # For example, this may be \"beat0_100_trance.wav\"
                                                        # You may use the full power of Ruby's regular expression
                                                        # system here: http://ruby-doc.org/core-2.1.1/Regexp.html
sample dir, /beat[0-9]0/, \"100\"                       # Play the first sample in the directory that both matches
                                                        # the regular expression /beat[0-9]0/ and contains the
                                                        # the substring \"100\".
                                                        # For example, this may be \"beat10_100_rave.wav\"",
        "
# Filtering built-in samples
                                                        # If you don't pass a directory source, you can filter over
                                                        # the built-in samples.
sample \"tabla_\"                                       # Play the first built-in sample that contains the substring
                                                        # \"tabla\"
sample \"tabla_\", 2                                    # Play the third built-in sample that contains the substring
                                                        # \"tabla\"",
        "
# Play with whole directories of samples
load_samples \"tabla_\"                                 # You may pass any of the source/filter options to load_samples
                                                        # to load all matching samples. This will load all the built-in
                                                        # samples containing the substring \"tabla_\"
live_loop :tabla do
  sample \"tabla_\", tick                               # Treat the matching samples as a ring and tick through them
  sleep 0.125
end",
        "
# Specify multiple sources
dir1 = \"/path/to/sample/directory\"
dir2 = \"/path/to/other/sample/directory\"
sample dir1, dir2, \"foo\"                              # Match the first sample that contains the string \"foo\" out of
                                                        # all the samples in dir1 and dir2 combined.
                                                        # Note that the sources must be listed before any filters.",
        "
# List contents recursively
dir = \"/path/to/sample/directory\"                     # By default the list of all top-level samples within the directory
                                                        # is considered.
dir_recursive = \"/path/to/sample/directory/**\"        # However, if you finish your directory string with ** then if that
                                                        # directory contains other directories then the samples within the
                                                        # subdirectories and their subsubdirectories in turn are considered.
sample dir, 0                                           # Play the first top-level sample in the directory
sample dir_recursive, 0                                 # Play the first sample found after combining all samples found in
                                                        # the directory and all directories within it recursively.
                                                        # Note that if there are many sub directories this may take some time
                                                        # to execute. However, the result is cached so subsequent calls will
                                                        # be fast.",
        "
# Bespoke filters
filter = lambda do |candidates|                         # If the built-in String, Regexp and index filters are not sufficient
  [candidates.choose]                                   # you may write your own. They need to be a function which takes a list
end                                                     # of paths to samples and return a list of samples. This one returns a
                                                        # list of a single randomly selected sample.
8.times do
  sample \"drum_\", filter                              # Play 8 randomly selected samples from the built-in sample set that also
  sleep 0.25                                            # contain the substring \"drum_\"
end",
        "
# Basic Onset Detection

sample :loop_tabla, start: 0, finish: 0.00763           # If you know the right start: and finish: values, you can extract a
                                                        # single drum hit from a longer sample. However, finding these values
                                                        # can be very time consuming.
sleep 1
                                                        # Instead of specifying the start: and finish: values manually you can
                                                        # use the onset: option to find them for you using an integer index.
sample :loop_tabla, onset: 0                            # onset: 0 will set the start: and finish: values so that the first
                                                        # percussive sound (something that shifts from quiet to loud quickly)
                                                        # is picked out.
sleep 1

sample :loop_tabla, onset: 1                            # We can easily find the second percussive sound in the sample with
                                                        # onset: 1",

        "

# Ticking through onsets

                                                        # The onsets are actually a ring so the index will wrap around. This
                                                        # means that if there are only 8 onsets in a sample, specifying an
                                                        # onset of 100 will still return one of the 8 onsets. This means we
                                                        # can use tick to work through each onset in sequence. This allows us
                                                        # to redefine the rhythm and tempo of a sample


live_loop :tabla do
  use_bpm 50                                            # We can choose our own BPM here - it doesn't need to match the sample
  sample :loop_tabla, onset: tick                       # tick through each onset in sequence
  sleep [0.125, 0.25].choose                            # randomly choose a delay between onset triggers
end
",
        "
# Random Onset Triggering
                                                        # We can easily pick a random onset using the pick fn
use_bpm 50
live_loop :tabla do
  sample :loop_tabla, onset: pick                       # Each time round the live loop we now trigger a random onset
  sleep [0.125, 0.25].choose                            # creating an infinite stream of randomly selected drums
end


        ",
        "
# Repeatable Random Onsets
                                                        # Instead of an infinite stream of choices, we can combine iteration
                                                        # and use_random_seed to create repeatable riffs:
live_loop :tabla do
  use_random_seed 30000                                 # every 8 times, reset the random seed, this resets the riff
  8.times do
    sample :loop_tabla, onset: pick
    sleep [0.125, 0.25].choose
  end
end

",
        "
#  Random Onset Duration
                                                            # Each onset has a variable length (determined by the sample contents).
                                                            # Therefore, if you wish to ensure each onset has a specific length it
                                                            # is necessary to use the sample's amplitude envelope.
                                                            # As the sample's envelope automatically changes the sustain: value to
                                                            # match the duration - you also need to override this with a value of 0.
live_loop :tabla do
  sample :loop_tabla, onset: pick, sustain: 0, release: 0.1 # Each drum onset will now be no longer than 0.1. Note that the envelope
                                                            # for a sample only determines the maximum duration of a sample trigger.
                                                            # If the actual audible duration of the onset is smaller than 0.1 then
                                                            # it will *not* be extended.
  sleep [0.125, 0.25].choose
end

",
        "
# Onset lambdas

                                                        # The onset index can be a lambda as well as an integer. If a lambda is
                                                        # given, it will be passed a ring of all of the onsets as an argument.
                                                        # This will be a ring of maps:

l = lambda {|c| puts c ; c[0]}                          # define a lambda which accepts a single argument, prints it and
                                                        # returns the first value. This particular example is essentially
                                                        # the same as using onset: 0 with the side effect of also printing out
                                                        # the full ring of onsets:

sample :loop_tabla, onset: l                            # (ring {:start=>0.0, :finish=>0.0076}, {:start=>0.0076, :finish 0.015}...)

                                                        # We are therefore free to define this lambda to do anything we want.
                                                        # This gives us very powerful control over the choice of onset. It is
                                                        # unlikely you will use this frequently, but it is a powerful tool
                                                        # that's there when you need it.

"
]




      def status
        @mod_sound_studio.status
      end
      doc name:          :status,
          introduced:    Version.new(2,0,0),
          summary:       "Get server status",
          doc:           "This returns a Hash of information about the synthesis environment. Mostly used for debugging purposes.",
          args:          [],
          opts:          nil,
          accepts_block: false,
          examples:      ["
puts status # Returns something similar to:
            # {
            #   :ugens=>10,
            #   :synths=>1,
            #   :groups=>7,
            #   :sdefs=>61,
            #   :avg_cpu=>0.20156468451023102,
            #   :peak_cpu=>0.36655542254447937,
            #   :nom_samp_rate=>44100.0,
            #   :act_samp_rate=>44099.9998411752,
            #   :audio_busses=>2,
            #   :control_busses=>0
            # }
"]




      def note(n, *args)
        # Short circuit out if possible.
        # Also recurse if necessary.
        case n
        when Numeric
          return n
        when Symbol
          return nil if(n == :r || n == :rest)
        when NilClass
          return nil
        when Proc
          return note(n.call, *args)
        when Hash
          raise "Unable to create a note from the Map: #{n.inspect}"
        end

        return Note.resolve_midi_note_without_octave(n) if args.empty?

        args_h = resolve_synth_opts_hash_or_array(args)
        octave = args_h[:octave]
        if octave
          Note.resolve_midi_note(n, octave)
        else
          Note.resolve_midi_note_without_octave(n)
        end
      end
      doc name:          :note,
      introduced:    Version.new(2,0,0),
      summary:       "Describe note",
      doc:           "Takes a midi note, a symbol (e.g. `:C`) or a string (e.g. `\"C\"`) and resolves it to a midi note. You can also pass an optional `octave:` parameter to get the midi note for a given octave. Please note - `octave:` param overrides any octave specified in a symbol i.e. `:c3`. If the note is `nil`, `:r` or `:rest`, then `nil` is returned (`nil` represents a rest)",
      args:          [[:note, :symbol_or_number]],
      opts:          {:octave => "The octave of the note. Overrides any octave declaration in the note symbol such as :c2. Default is 4"},
      accepts_block: false,
      examples:      ["
# These all return 60 which is the midi number for middle C (octave 4)
puts note(60)
puts note(:C)
puts note(:C4)
puts note('C')
",
        "# returns 60 - octave param has no effect if we pass in a number
puts note(60, octave: 2)

# These all return 36 which is the midi number for C2 (two octaves below middle C)
puts note(:C, octave: 2)
puts note(:C4, octave: 2) # note the octave param overrides any octaves specified in a symbol
puts note('C', octave: 2)
"]




      def note_range(low_note, high_note, *opts)
        opts_h = resolve_synth_opts_hash_or_array(opts)
        low_note = note(low_note)
        high_note = note(high_note)

        potential_note_range = Range.new(low_note, high_note)

        if opts_h[:pitches]
          pitch_classes = opts_h[:pitches].map {|x| Note.resolve_note_name(x) }

          note_pool = potential_note_range.select {|n|
            pitch_classes.include? Note.resolve_note_name(n)
          }
        else
          note_pool = potential_note_range
        end

        note_pool.ring
      end
      doc name:           :note_range,
      introduced:     Version.new(2,6,0),
      summary:        "Get a range of notes",
      args:           [[:low_note, :note], [:high_note, :note]],
      returns:        :ring,
      opts:           {:pitches => "An array of notes (symbols or ints) to filter on. Octave information is ignored."},
      accepts_block:  false,
      doc:            "Produces a ring of all the notes between a low note and a high note. By default this is chromatic (all the notes) but can be filtered with a pitches: argument. This opens the door to arpeggiator style sequences and other useful patterns. If you try to specify only pitches which aren't in the range it will raise an error - you have been warned!",
      examples:       [
        "(note_range :c4, :c5) # => (ring 60,61,62,63,64,65,66,67,68,69,70,71,72)",
        "(note_range :c4, :c5, pitches: (chord :c, :major)) # => (ring 60,64,67,72)",
        "(note_range :c4, :c6, pitches: (chord :c, :major)) # => (ring 60,64,67,72,76,79,84)",
        "(note_range :c4, :c5, pitches: (scale :c, :major)) # => (ring 60,62,64,65,67,69,71,72)",
        "(note_range :c4, :c5, pitches: [:c4, :g2]) # => (ring 60,67,72)",
        "live_loop :arpeggiator do
  # try changing the chord
  play (note_range :c4, :c5, pitches: (chord :c, :major)).tick
  sleep 0.125
end"
      ]






      def note_info(n, *args)
        raise Exception.new("note_info argument must be a valid note. Got nil.") if(n.nil?)
        args_h = resolve_synth_opts_hash_or_array(args)
        octave = args_h[:octave]
        SonicPi::Note.new(n, octave)
      end
      doc name:          :note_info,
          introduced:    Version.new(2,0,0),
          summary:       "Get note info",
          doc:           "Returns an instance of `SonicPi::Note`. Please note - `octave:` param overrides any octave specified in a symbol i.e. `:c3`",
          args:          [[:note, :symbol_or_number]],
          opts:          {:octave => "The octave of the note. Overrides any octave declaration in the note symbol such as :c2. Default is 4"},
          accepts_block: false,
          examples:      [%Q{
puts note_info(:C, octave: 2)
# returns #<SonicPi::Note :C2>}]





      def degree(degree, tonic, scale)
        Scale.resolve_degree(degree, tonic, scale)
      end
      doc name:           :degree,
          introduced:         Version.new(2,1,0),
          summary:            "Convert a degree into a note",
          doc:                "For a given scale and tonic it takes a symbol `:i`, `:ii`, `:iii`, `:iv`,`:v`, `:vi`, `:vii` or a number `1`-`7` and resolves it to a midi note.",
          args:               [[:degree, :symbol_or_number], [:tonic, :symbol], [:scale, :symbol]],
          accepts_block:      false,
          examples:           [%Q{
play degree(:ii, :D3, :major)
play degree(2, :C3, :minor)
}]




      def scale(tonic_or_name, *opts)
        tonic = 0
        name = :minor
        if opts.size == 0
          name = tonic_or_name
        elsif (opts.size == 1) && opts[0].is_a?(Hash)
          name = tonic_or_name
        else
          tonic = tonic_or_name
          name = opts.shift
        end

        opts = resolve_synth_opts_hash_or_array(opts)
        opts = {:num_octaves => 1}.merge(opts)
        Scale.new(tonic, name,  opts[:num_octaves]).ring
      end
      doc name:          :scale,
          introduced:    Version.new(2,0,0),
          summary:       "Create scale",
          doc:           "Creates a ring of MIDI note numbers when given a tonic note and a scale name. Also takes an optional `num_octaves:` parameter (octave `1` is the default). If only passed the scale name, the tonic defaults to 0. See examples.",
          args:          [[:tonic, :symbol], [:name, :symbol]],
          returns:        :ring,
          opts:          {:num_octaves => "The number of octaves you'd like the scale to consist of. More octaves means a larger scale. Default is 1."},
          accepts_block: false,
          intro_fn:       true,
          memoize:        true,
          examples:      ["
puts (scale :C, :major) # returns the following ring of MIDI note numbers: (ring 60, 62, 64, 65, 67, 69, 71, 72)",
        "# anywhere you can use a list or ring of notes, you can also use scale
play_pattern (scale :C, :major)",
        "# you can use the :num_octaves parameter to get more notes
play_pattern (scale :C, :major, num_octaves: 2)",
        "# Scales can start with any note:
puts (scale 50, :minor) #=> (ring 50, 52, 53, 55, 57, 58, 60, 62)
puts (scale 50.1, :minor) #=> (ring 50.1, 52.1, 53.1, 55.1, 57.1, 58.1, 60.1, 62.1)
puts (scale :minor) #=> (ring 0, 2, 3, 5, 7, 8, 10, 12)",


" # scales are also rings
live_loop :scale_player do
  play (scale :Eb3, :super_locrian).tick, release: 0.1
  sleep 0.125
end",

        " # scales starting with 0 are useful in combination with sample's rpitch:
live_loop :scaled_sample do
  sample :bass_trance_c, rpitch: (scale 0, :minor).tick
  sleep 1
end",


"# Sonic Pi supports a large range of scales:

(scale :C, :diatonic)
(scale :C, :ionian)
(scale :C, :major)
(scale :C, :dorian)
(scale :C, :phrygian)
(scale :C, :lydian)
(scale :C, :mixolydian)
(scale :C, :aeolian)
(scale :C, :minor)
(scale :C, :locrian)
(scale :C, :hex_major6)
(scale :C, :hex_dorian)
(scale :C, :hex_phrygian)
(scale :C, :hex_major7)
(scale :C, :hex_sus)
(scale :C, :hex_aeolian)
(scale :C, :minor_pentatonic)
(scale :C, :yu)
(scale :C, :major_pentatonic)
(scale :C, :gong)
(scale :C, :egyptian)
(scale :C, :shang)
(scale :C, :jiao)
(scale :C, :zhi)
(scale :C, :ritusen)
(scale :C, :whole_tone)
(scale :C, :whole)
(scale :C, :chromatic)
(scale :C, :harmonic_minor)
(scale :C, :melodic_minor_asc)
(scale :C, :hungarian_minor)
(scale :C, :octatonic)
(scale :C, :messiaen1)
(scale :C, :messiaen2)
(scale :C, :messiaen3)
(scale :C, :messiaen4)
(scale :C, :messiaen5)
(scale :C, :messiaen6)
(scale :C, :messiaen7)
(scale :C, :super_locrian)
(scale :C, :hirajoshi)
(scale :C, :kumoi)
(scale :C, :neapolitan_major)
(scale :C, :bartok)
(scale :C, :bhairav)
(scale :C, :locrian_major)
(scale :C, :ahirbhairav)
(scale :C, :enigmatic)
(scale :C, :neapolitan_minor)
(scale :C, :pelog)
(scale :C, :augmented2)
(scale :C, :scriabin)
(scale :C, :harmonic_major)
(scale :C, :melodic_minor_desc)
(scale :C, :romanian_minor)
(scale :C, :hindu)
(scale :C, :iwato)
(scale :C, :melodic_minor)
(scale :C, :diminished2)
(scale :C, :marva)
(scale :C, :melodic_major)
(scale :C, :indian)
(scale :C, :spanish)
(scale :C, :prometheus)
(scale :C, :diminished)
(scale :C, :todi)
(scale :C, :leading_whole)
(scale :C, :augmented)
(scale :C, :purvi)
(scale :C, :chinese)
(scale :C, :lydian_minor)
(scale :C, :blues_major)
(scale :C, :blues_minor)
"]




      def chord_degree(degree, tonic, scale=:major, number_of_notes=4, *opts)
        opts = resolve_synth_opts_hash_or_array(opts)
        opts = {invert: 0}.merge(opts)

        chord_invert(Chord.resolve_degree(degree, tonic, scale, number_of_notes), opts[:invert]).ring
      end
      doc name:          :chord_degree,
          introduced:    Version.new(2,1,0),
          summary:       "Construct chords of stacked thirds, based on scale degrees",
          doc:           "In music we build chords from scales. For example, a C major chord is made by taking the 1st, 3rd and 5th notes of the C major scale (C, E and G). If you do this on a piano you might notice that you play one, skip one, play one, skip one etc. If we use the same spacing and start from the second note in C major (which is a D), we get a D minor chord which is the 2nd, 4th and 6th notes in C major (D, F and A). We can move this pattern all the way up or down the scale to get different types of chords. `chord_degree` is a helper method that returns a ring of midi note numbers when given a degree (starting point in a scale) which is a symbol `:i`, `:ii`, `:iii`, `:iv`, `:v`, `:vi`, `:vii` or a number `1`-`7`. The second argument is the tonic note of the scale, the third argument is the scale type and finally the fourth argument is number of notes to stack up in the chord. If we choose 4 notes from degree `:i` of the C major scale, we take the 1st, 3rd, 5th and 7th notes of the scale to get a C major 7 chord.",
          args:          [[:degree, :symbol_or_number], [:tonic, :symbol], [:scale, :symbol], [:number_of_notes, :number]],
          returns:       :ring,
          opts:          nil,
          accepts_block: false,
          memoize:       true,
          examples:      ["puts (chord_degree :i, :A3, :major) # returns a ring of midi notes - (ring 57, 61, 64, 68) - an A major 7 chord",
        "play (chord_degree :i, :A3, :major, 3)",
        "play (chord_degree :ii, :A3, :major, 3) # Chord ii in A major is a B minor chord",
        "play (chord_degree :iii, :A3, :major, 3) # Chord iii in A major is a C# minor chord",
        "play (chord_degree :iv, :A3, :major, 3) # Chord iv in A major is a D major chord",
        "play (chord_degree :i, :C4, :major, 4) # Taking four notes is the default. This gives us 7th chords - here it plays a C major 7",
        "play (chord_degree :i, :C4, :major, 5) # Taking five notes gives us 9th chords - here it plays a C major 9 chord",
      ]




      def chord(tonic_or_name, *opts)
        tonic = 0
        name = :minor
        if opts.size == 0
          tonic = tonic_or_name
          name = /[[:upper:]]/.match(tonic_or_name.to_s[0]) ? :major : :minor
        elsif (opts.size == 1) && opts[0].is_a?(Hash)
          name = tonic_or_name
        else
          tonic = tonic_or_name
          name = opts.shift
        end

        return [] unless tonic
        opts = resolve_synth_opts_hash_or_array(opts)
        c = []
        if is_list_like?(tonic)
          raise "List passed as parameter to chord needs two elements i.e. (chord [:e3, :minor]), you passed: #{tonic.inspect}" unless tonic.size == 2
          c = Chord.new(tonic[0], tonic[1], opts[:num_octaves])
        else
          c = Chord.new(tonic, name, opts[:num_octaves])
        end
        c = chord_invert(c, opts[:i]) if opts[:i]
        return c.ring
      end
      doc name:          :chord,
          introduced:    Version.new(2,0,0),
          summary:       "Create chord",
          doc:           "Creates an immutable ring of Midi note numbers when given a tonic note and a chord type. If only passed a chord type, will default the tonic to 0. See examples.",
          args:          [[:tonic, :symbol], [:name, :symbol]],
          returns:        :ring,
          opts:          {invert: "Apply the specified num inversions to chord. See the fn `chord_invert`.",
          num_octaves:   "Create an arpeggio of the chord over n octaves"},
          accepts_block: false,
          intro_fn:      true,
          memoize:       true,
          examples:      ["
puts (chord :e, :minor) # returns a ring of midi notes - (ring 64, 67, 71)
",
        "# Play all the notes together
play (chord :e, :minor)",
"
# Chord inversions (see the fn chord_invert)
play (chord :e3, :minor, invert: 0) # Play the basic :e3, :minor chord - (ring 52, 55, 59)
play (chord :e3, :minor, invert: 1) # Play the first inversion of :e3, :minor - (ring 55, 59, 64)
play (chord :e3, :minor, invert: 2) # Play the first inversion of :e3, :minor - (ring 59, 64, 67)
",

"# You can create a chord without a tonic:
puts (chord :minor) #=> (ring 0, 3, 7)",

"# chords are great for arpeggiators
live_loop :arp do
  play chord(:e, :minor, num_octaves: 2).tick, release: 0.1
  sleep 0.125
end",
        "# Sonic Pi supports a large range of chords
 # Notice that the more exotic ones have to be surrounded by ' quotes
(chord :C, '1')
(chord :C, '5')
(chord :C, '+5')
(chord :C, 'm+5')
(chord :C, :sus2)
(chord :C, :sus4)
(chord :C, '6')
(chord :C, :m6)
(chord :C, '7sus2')
(chord :C, '7sus4')
(chord :C, '7-5')
(chord :C, 'm7-5')
(chord :C, '7+5')
(chord :C, 'm7+5')
(chord :C, '9')
(chord :C, :m9)
(chord :C, 'm7+9')
(chord :C, :maj9)
(chord :C, '9sus4')
(chord :C, '6*9')
(chord :C, 'm6*9')
(chord :C, '7-9')
(chord :C, 'm7-9')
(chord :C, '7-10')
(chord :C, '9+5')
(chord :C, 'm9+5')
(chord :C, '7+5-9')
(chord :C, 'm7+5-9')
(chord :C, '11')
(chord :C, :m11)
(chord :C, :maj11)
(chord :C, '11+')
(chord :C, 'm11+')
(chord :C, '13')
(chord :C, :m13)
(chord :C, :add2)
(chord :C, :add4)
(chord :C, :add9)
(chord :C, :add11)
(chord :C, :add13)
(chord :C, :madd2)
(chord :C, :madd4)
(chord :C, :madd9)
(chord :C, :madd11)
(chord :C, :madd13)
(chord :C, :major)
(chord :C, :M)
(chord :C, :minor)
(chord :C, :m)
(chord :C, :major7)
(chord :C, :dom7)
(chord :C, '7')
(chord :C, :M7)
(chord :C, :minor7)
(chord :C, :m7)
(chord :C, :augmented)
(chord :C, :a)
(chord :C, :diminished)
(chord :C, :dim)
(chord :C, :i)
(chord :C, :diminished7)
(chord :C, :dim7)
(chord :C, :i7)
"]




      def chord_invert(notes, shift)
        raise "Inversion shift value must be a number, got #{shift.inspect}" unless shift.is_a?(Numeric)
        shift = shift.round
        raise "Notes must be a list of notes, got #{notes.inspect}" unless is_list_like?(notes)
        if(shift > 0)
          chord_invert(notes.to_a[1..-1] + [notes.to_a[0]+12], shift-1)
        elsif(shift < 0)
          chord_invert((notes.to_a[0..-2] + [notes.to_a[-1]-12]).sort, shift+1)
        else
          notes.ring
        end
      end
      doc name:          :chord_invert,
          introduced:    Version.new(2,6,0),
          summary:       "Chord inversion",
          doc:           "Given a set of notes, apply a number of inversions indicated by the `shift` parameter. Inversions being an increase to notes if `shift` is positive or decreasing the notes if `shift` is negative.

An inversion is simply rotating the chord and shifting the wrapped notes up or down an octave. For example, consider the chord :e3, :minor - `(ring 52, 55, 59)`. When we invert it once, we rotate the notes around to `(ring 55, 59, 52)`. However, because note 52 is wrapped round, it's shifted up an octave (12 semitones) so the actual first inversion of the chord :e3, :minor is `(ring 55, 59, 52 + 12)` or `(ring 55, 59, 64)`.

Note that it's also possible to directly invert chords on creation with the `invert:` opt - `(chord :e3, :minor, invert: 2)`",
          args:          [[:notes, :list], [:shift, :number]],
          returns:        :ring,
          opts:          nil,
          accepts_block: false,
          examples:      ["
play (chord_invert (chord :A3, \"M\"), 0) #No inversion     - (ring 57, 61, 64)
sleep 1
play (chord_invert (chord :A3, \"M\"), 1) #First inversion  - (ring 61, 64, 69)
sleep 1
play (chord_invert (chord :A3, \"M\"), 2) #Second inversion - (ring 64, 69, 73)
"]


      # keep for backwards compatibility
      def invert_chord(*args)
        chord_invert(*args)
      end



      def control(*args)

        if (!args.first.is_a?(SonicPi::Node || !args.first.nil?))
          # we haven't specified a node to control - take it from the TL
            node = __thread_locals.get(:sonic_pi_local_last_triggered_node)
        else
            node = args.shift
        end
        return nil if node.nil?

        raise "You may only control a SynthNode. You tried to control a #{node.class}: #{node.inspect}" unless node.is_a?(Node)
        args_h = resolve_synth_opts_hash_or_array(args)
        args_h = args_h.to_h
        return nil unless should_trigger?(args_h)

        info = node.info
        defaults = info ? info.arg_defaults : {}

        if node.info
          args_h = info.munge_opts(@mod_sound_studio, args_h)
          resolve_midi_args!(args_h, info)
          resolve_buffer_args!(args_h, info)
          add_arg_slide_times!(args_h, info)
          scale_time_args_to_bpm!(args_h, info, false)
        end

        if node.is_a?(ChordGroup)
          note = args_h.delete(:note)
          notes = args_h.delete(:notes)
          notes = note if note && !notes
          normalise_args! args_h, defaults
          # don't normalise notes key as it is special
          # when controlling ChordGroups.
          # TODO: remove this hard coded behaviour
          if notes
            notes = [notes] unless is_list_like?(notes)
            args_h[:notes] = notes.map{|n| normalise_transpose_and_tune_note_from_args(n, args_h)}
          end
        else
          note = args_h[:note]
          if note
            note = normalise_transpose_and_tune_note_from_args(note, args_h)
            args_h[:note] = note
          end
          normalise_args! args_h, defaults
        end

        if __thread_locals.get(:sonic_pi_mod_sound_check_synth_args)
          info.ctl_validate!(args_h) if info
        end

        if __thread_locals.get(:sonic_pi_mod_sound_timing_guarantees)
          unless in_good_time?
            __delayed_message "!! Out of time, skipping: control node #{node.id}, #{arg_h_pp(args_h)}"
            return node
          end
        end

        node.control args_h

        unless __thread_locals.get(:sonic_pi_mod_sound_synth_silent)
          __delayed_message "control node #{node.id}, #{arg_h_pp(args_h)}"
        end
        return node
      end
      doc name:          :control,
          introduced:    Version.new(2,0,0),
          summary:       "Control running synth",
          doc:           "Control a running synth node by passing new parameters to it. A synth node represents a running synth and can be obtained by assigning the return value of a call to play or sample or by specifying a parameter to the do/end block of an FX. You may modify any of the parameters you can set when triggering the synth, sample or FX. See documentation for opt details. If the synth to control is a chord, then control will change all the notes of that chord group at once to a new target set of notes - see example. Also, you may use the on: opt to conditionally trigger the control - see the docs for the `synth` and `sample` fns for more information.

If no synth to control is specified, then the last synth triggered by the current (or parent) thread will be controlled - see example below.",
          args:          [[:node, :synth_node]],
          opts:          {},
          accepts_block: false,
          examples:      ["
## Basic control

my_node = play 50, release: 5, cutoff: 60 # play note 50 with release of 5 and cutoff of 60. Assign return value to variable my_node
sleep 1 # Sleep for a second
control my_node, cutoff: 70 # Now modify cutoff from 60 to 70, sound is still playing
sleep 1 # Sleep for another second
control my_node, cutoff: 90 # Now modify cutoff from 70 to 90, sound is still playing",
        "
## Combining control with slide opts allows you to create nice transitions.

s = synth :prophet, note: :e1, cutoff: 70, cutoff_slide: 8, release: 8 # start synth and specify slide time for cutoff opt
control s, cutoff: 130 # Change the cutoff value with a control.
                       # Cutoff will now slide over 8 beats from 70 to 130",

        "
## Use a short slide time and many controls to create a sliding melody

notes = (scale :e3, :minor_pentatonic, num_octaves: 2).shuffle # get a random ordering of a scale

s = synth :beep, note: :e3, sustain: 8, note_slide: 0.05 # Start our synth running with a long sustain and short note slide time
64.times do
  control s, note: notes.tick                            # Keep quickly changing the note by ticking through notes repeatedly
  sleep 0.125
end
",

        "
## Controlling FX

with_fx :bitcrusher, sample_rate: 1000, sample_rate_slide: 8 do |bc| # Start FX but also use the handy || goalposts
                                                                     # to grab a handle on the running FX. We can call
                                                                     # our handle anything we want. Here we've called it bc
  sample :loop_garzul, rate: 1
  control bc, sample_rate: 5000                                      # We can use our handle bc now just like we used s in the
                                                                     # previous example to modify the FX as it runs.
end",
        "
## Controlling chords

cg = play (chord :e4, :minor), sustain: 2  # start a chord
sleep 1
control cg, notes: (chord :c3, :major)     # transition to new chord.
                                           # Each note in the original chord is mapped onto
                                           # the equivalent in the new chord.
",
        "
## Sliding between chords

cg = play (chord :e4, :minor), sustain: 4, note_slide: 3  # start a chord
sleep 1
control cg, notes: (chord :c3, :major)                    # slide to new chord.
                                                          # Each note in the original chord is mapped onto
                                                          # the equivalent in the new chord.
",
        "
## Sliding from a larger to smaller chord

cg = play (chord :e3, :m13), sustain: 4, note_slide: 3  # start a chord with 7 notes
sleep 1
control cg, notes: (chord :c3, :major)                    # slide to new chord with fewer notes (3)
                                                          # Each note in the original chord is mapped onto
                                                          # the equivalent in the new chord using ring-like indexing.
                                                          # This means that the 4th note in the original chord will
                                                          # be mapped onto the 1st note in the second chord and so-on.
",
        "
## Sliding from a smaller to larger chord
cg = play (chord :c3, :major), sustain: 4, note_slide: 3  # start a chord with 3 notes
sleep 1
control cg, notes: (chord :e3, :m13)                     # slide to new chord with more notes (7)
                                                          # Each note in the original chord is mapped onto
                                                          # the equivalent in the new chord.
                                                          # This means that the 4th note in the new chord
                                                          # will not sound as there is no 4th note in the
                                                          # original chord.
",

        "
## Changing the slide rate

s = synth :prophet, note: :e1, release: 8, cutoff: 70, cutoff_slide: 8 # Start a synth playing with a long cutoff slide
sleep 1                                                                # wait a beat
control s, cutoff: 130                                                 # change the cutoff so it starts sliding slowly
sleep 3                                                                # wait for 3 beats
control s, cutoff_slide: 1                                             # Change the cutoff_slide - the cutoff now slides more quickly to 130
                                                                       # it will now take 1 beat to slide from its *current* value
                                                                       # (somewhere between 70 and 130) to 130
",

        "
## Controlling the last triggered synth

synth :prophet, note: :e1, release: 8                                  # Every time a synth is triggered, Sonic Pi automatically remembers the node
sleep 1
16.times do
  control note: (octs :e1, 3).tick                                     # This means we don't need to use an explicit variable to control the synth
  sleep 0.125                                                          # we last triggered.
end",
        "
## Controlling multiple synths without variables

synth :beep, release: 4                  # Trigger a beep synth
sleep 0.1
control note: :e5                        # Control last triggered synth (:beep)
sleep 0.5
synth :dsaw, release: 4                  # Next, trigger a dsaw synth
sleep 0.1
control note: :e4                        # Control last triggered synth (:dsaw)

"

      ]




      def kill(node)
        in_good_time?
        return nil if node.nil?

        alive = node.live?
        node.kill
        if alive
          __delayed_message "killing sound #{node.id}"
        else
          __delayed_message "not killing sound #{node.id} (already killed)"
        end
      end
      doc name:          :kill,
          introduced:    Version.new(2,0,0),
          summary:       "Kill synth",
          doc:           "Kill a running synth sound or sample. In order to kill a sound, you need to have stored a reference to it in a variable.",
          args:          [[:node, :synth_node]],
          opts:          {},
          accepts_block: false,
          examples:      ["
# store a reference to a running synth in a variable called foo:
foo = play 50, release: 4
sleep 1
# foo is still playing, but we can kill it early:
kill foo
",
        "bar = sample :loop_amen
sleep 0.5
kill bar"]




      def sample_names(group)
        g = Synths::BaseInfo.grouped_samples[group]
        raise "Unknown sample group #{group.inspect}" unless g
        g[:samples].sort.ring
      end
      doc name:          :sample_names,
          introduced:    Version.new(2,0,0),
          summary:       "Get sample names",
          doc:           "Return a ring of sample names for the specified group",
          args:          [[:group, :symbol]],
          returns:        :ring,
          opts:          nil,
          accepts_block: false,
          memoize:       true,
          examples:      []




      def all_sample_names
        Synths::BaseInfo.all_samples.sort.ring
      end
      doc name:          :all_sample_names,
          introduced:    Version.new(2,0,0),
          summary:       "Get all sample names",
          doc:           "Return a list of all the sample names available",
          args:          [],
          opts:          nil,
          accepts_block: false,
          memoize:       true,
          examples:      []




      def sample_groups
        Synths::BaseInfo.grouped_samples.keys.sort.ring
      end
      doc name:          :sample_groups,
          introduced:    Version.new(2,0,0),
          summary:       "Get all sample groups",
          doc:           "Return a list of all the sample groups available",
          args:          [],
          opts:          nil,
          accepts_block: false,
          memoize:       true,
          examples:      []




      def synth_names
        Synths::BaseInfo.all_synths.sort.ring
      end
      doc name:          :synth_names,
          introduced:    Version.new(2,9,0),
          summary:       "Get all synth names",
          doc:           "Return a list of all the synths available",
          args:          [],
          opts:          nil,
          accepts_block: false,
          memoize:       true,
          examples:      []


      def fx_names
        Synths::BaseInfo.all_fx.sort.ring
      end
      doc name:          :fx_names,
          introduced:    Version.new(2,10,0),
          summary:       "Get all FX names",
          doc:           "Return a list of all the FX available",
          args:          [],
          opts:          nil,
          accepts_block: false,
          memoize:       true,
          examples:      []


      def load_synthdefs(path=synthdef_path)
        path = File.expand_path(path)
        raise "No directory exists called #{path.inspect}" unless File.exist? path
        @mod_sound_studio.load_synthdefs(path)
        __info "Loaded synthdefs in path #{path}"
      end
      doc name:          :load_synthdefs,
          introduced:    Version.new(2,0,0),
          summary:       "Load external synthdefs",
          doc:           "Load all pre-compiled synth designs in the specified directory. The binary files containing synth designs need to have the extension `.scsyndef`. This is useful if you wish to use your own SuperCollider synthesiser designs within Sonic Pi.

## Important notes

You may not trigger external synthdefs unless you enable the following GUI preference:

```
Studio -> Synths and FX -> Enable external synths and FX
```

Also, if you wish your synth to work with Sonic Pi's automatic stereo sound infrastructure *you need to ensure your synth outputs a stereo signal* to an audio bus with an index specified by a synth arg named `out_bus`. For example, the following synth would work nicely:


    (
    SynthDef(\\piTest,
             {|freq = 200, amp = 1, out_bus = 0 |
               Out.ar(out_bus,
                      SinOsc.ar([freq,freq],0,0.5)* Line.kr(1, 0, 5, amp, doneAction: 2))}
    ).writeDefFile(\"/Users/sam/Desktop/\")
    )


    ",
      args:          [[:path, :string]],
      opts:          nil,
      accepts_block: false,
      examples:      ["load_synthdefs \"~/Desktop/my_noises\" # Load all synthdefs in my_noises folder"]


      def scale_names
        Scale::SCALE.keys.sort.ring
      end
      doc name:          :scale_names,
          introduced:    Version.new(2,6,0),
          summary:       "All scale names",
          doc:           "Returns a ring containing all scale names known to Sonic Pi",
          args:          [],
          opts:          nil,
          accepts_block: false,
          memoize:       true,
          examples:      ["puts scale_names #=>  prints a list of all the scales"]


      def chord_names
        Chord::CHORD_NAMES.ring
      end
      doc name:          :chord_names,
          introduced:    Version.new(2,6,0),
          summary:       "All chord names",
          doc:           "Returns a ring containing all chord names known to Sonic Pi",
          args:          [],
          opts:          nil,
          accepts_block: false,
          memoize:       true,
          examples:      ["puts chord_names #=>  prints a list of all the chords"]

      private

      def init_tuning
        @tuning = Tuning.new
      end

      def normalise_args!(args_h, defaults={})
        args_h.keys.each do |k|
          v = args_h[k]
          case v
          when Numeric, Buffer
            # do nothing
          when Proc
            res = v.call
            case res
            when TrueClass
              args_h[k] = 1.0
            when FalseClass
              args_h[k] = 0.0
            when NilClass
              args_h[k] = nil
            else
              begin
                args_h[k] = res.to_f
              rescue
                raise "Unable to normalise argument with key #{k.inspect} and value #{res.inspect}"
              end
            end
          when Symbol
            # Allow vals to be keys to other vals
            # But only one level deep...
            args_h[k] = (args_h[v] || defaults[v]).to_f
          when TrueClass
            args_h[k] = 1.0
          when FalseClass
            args_h[k] = 0.0
          when NilClass
            args_h[k] = nil
          else
            begin
              args_h[k] = v.to_f
            rescue
              raise "Unable to normalise argument with key #{k.inspect} and value #{v.inspect}"
            end
          end
        end
        args_h
      end

      def find_sample_with_path(path)
        ["wav", "wave", "aif", "aiff", "flac"].each do |ext|
          full = "#{path}.#{ext}"
          return full if File.exist?(full)
        end
        return nil
      end

      def complex_sampler_args?(args_h)
        # break out early if any of the 'complex' keys exist in the
        # args map:
        return false if args_h.empty?
        return !(args_h.keys - @simple_sampler_args).empty?
      end


      def resolve_specific_sampler(num_chans, args_h)
        if complex_sampler_args?(args_h)
          #complex
          (num_chans == 1) ? :mono_player : :stereo_player
        else
          #basic
          (num_chans == 1) ? :basic_mono_player : :basic_stereo_player
        end
      end

      def buffer_save(buffer, path)
        @mod_sound_studio.save_buffer!(buffer, path)
      end

      def trigger_sampler(path, args_h, group=current_group)
        args_h = args_h.to_h
        case path
        when Buffer
          buf_info = path
          if buf_info.path
            path = buf_info.path
          else
            #path = path[0]
            path = "unknown"
          end
        else
          buf_info = load_sample_at_path(path)
        end
        sn = resolve_specific_sampler(buf_info.num_chans, args_h)

        info = Synths::SynthInfo.get_info(sn)
        args_h = normalise_and_resolve_sample_args(path, args_h, info)

        buf_id = buf_info.id

        if __thread_locals.get(:sonic_pi_mod_sound_timing_guarantees)
          unless in_good_time?
            if args_h.empty?
              __delayed_message "!! Out of time, skipping: sample #{path.inspect}"
            else
              __delayed_message "!! Out of time, skipping: sample #{path.inspect}, #{arg_h_pp(args_h)}"
            end
            return BlankNode.new(args_h)
          end
        end


        unless __thread_locals.get(:sonic_pi_mod_sound_synth_silent)
          if args_h.empty?
            __delayed_message "sample #{File.dirname(path).inspect},\n           #{File.basename(path).inspect}"
          else
            __delayed_message "sample #{File.dirname(path).inspect},\n           #{File.basename(path).inspect}, #{arg_h_pp(args_h)}"

          end
        end
        add_arg_slide_times!(args_h, info)
        args_h[:buf] = buf_id
        return trigger_synth(sn, args_h, group, info)
      end


      def trigger_inst(synth_name, args_h, info=nil, group=current_group)
        processed_args = normalise_and_resolve_synth_args(args_h, info, true)

        if __thread_locals.get(:sonic_pi_mod_sound_timing_guarantees)
          unless in_good_time?
            __delayed_message "!! Out of time, skipping: synth #{synth_name.inspect}, #{arg_h_pp(processed_args)}"

            return BlankNode.new(args_h)
          end
        end


        unless __thread_locals.get(:sonic_pi_mod_sound_synth_silent)
          __delayed_message "synth #{synth_name.inspect}, #{arg_h_pp(processed_args)}"
        end

        add_arg_slide_times!(processed_args, info) if info
        out_bus = current_out_bus
        trigger_synth(synth_name, processed_args, group, info, false, out_bus)
      end

      def trigger_chord(synth_name, notes, args_a_or_h, group=current_group)
        sn = synth_name.to_sym
        info = Synths::SynthInfo.get_info(sn)
        args_h = resolve_synth_opts_hash_or_array(args_a_or_h)
        args_h = normalise_and_resolve_synth_args(args_h, info, true)

        chord_group = @mod_sound_studio.new_group(:tail, group, "CHORD")
        cg = ChordGroup.new(chord_group, notes, info)

        if __thread_locals.get(:sonic_pi_mod_sound_timing_guarantees)
          unless in_good_time?
            __delayed_message "!! Out of time, skipping: synth #{sn.inspect}, #{arg_h_pp({note: notes}.merge(args_h))}"
            return BlankNode.new(args_h)
          end
        end

        unless __thread_locals.get(:sonic_pi_mod_sound_synth_silent)
          __delayed_message "synth #{sn.inspect}, #{arg_h_pp({note: notes}.merge(args_h))}"
        end

        # Scale down amplitude based on number of notes in chord
        amp = args_h[:amp] || 1.0
        args_h[:amp] = amp.to_f / notes.size

        nodes = []

        notes.each do |note|
          if note
            args_h[:note] = note
            nodes << trigger_synth(synth_name, args_h, cg, info)
          end
        end
        cg.sub_nodes = nodes

        # TODO: ensure this behaviour gets moved to the group functionality once built
        __thread_locals.set(:sonic_pi_local_last_triggered_node, cg)
        cg
      end

      def trigger_fx(synth_name, args_h, info, in_bus, group=current_group, now=false, t_minus_delta=false)
        args_h = normalise_and_resolve_synth_args(args_h, info, false)
        add_arg_slide_times!(args_h, info)
        out_bus = current_out_bus
        n = trigger_synth(synth_name, args_h, group, info, now, out_bus, t_minus_delta, :tail)
        FXNode.new(n, in_bus, out_bus)
      end

      # Function that actually triggers synths now that all args are resolved
      def trigger_synth(synth_name, args_h, group, info, now=false, out_bus=nil, t_minus_delta=false, pos=:tail)

        add_out_bus_and_rand_buf!(args_h, out_bus, info)

        synth_name = info ? info.scsynth_name : synth_name

        validate_if_necessary! info, args_h
        return BlankNode.new(args_h) unless should_trigger?(args_h)

        ensure_good_timing!

        __no_kill_block do

          info.on_start(@mod_sound_studio, args_h) if info
          s = @mod_sound_studio.trigger_synth synth_name, group, args_h, info, now, t_minus_delta, pos

          fx_tracker = __system_thread_locals.get(:sonic_pi_local_mod_fx_tracker)
          tl_tracker = __current_tracker
          fx_tracker.synth_started(s) if fx_tracker

          tl_tracker.synth_started(s)

          s.on_next_move do
            fx_tracker.synth_finished(s) if fx_tracker
            tl_tracker.synth_finished(s)
          end

          s.on_destroyed do
            if info
              Thread.new do
                info.on_finish(@mod_sound_studio, args_h)
              end
            end
            fx_tracker.synth_finished(s) if fx_tracker
            tl_tracker.synth_finished(s)
          end
          __thread_locals.set(:sonic_pi_local_last_triggered_node, s)
          s
        end
      end


      def trigger_live_synth(synth_name, args_h, group, info, now=false, out_bus=nil, t_minus_delta=false, pos=:tail, live_id=nil)

        add_out_bus_and_rand_buf!(args_h, out_bus, info)

        synth_name = info ? info.scsynth_name : synth_name

        validate_if_necessary! info, args_h
        return BlankNode.new(args_h) unless should_trigger?(args_h)

        ensure_good_timing!

        fx_tracker = __system_thread_locals.get(:sonic_pi_local_mod_fx_tracker)
        tl_tracker = __current_tracker
        stud = @mod_sound_studio
        group_id = group.id

        on_move_blk = lambda do |sn|
          sn.on_next_move do |args|
            # check to see if this move is a move from the latest group
            if args[1] > group_id
              fx_tracker.synth_finished([sn, group_id]) if fx_tracker
              tl_tracker.synth_finished([sn, group_id]) if tl_tracker
            else
              :keep_on_move_lambda
            end
          end
        end

        pre_trig_blk = lambda do |sn|
          fx_tracker.synth_started([sn, group_id]) if fx_tracker
          tl_tracker.synth_started([sn, group_id]) if tl_tracker

          sn.on_destroyed(:sonic_pi_live_synth_finish) do
            if info
              Thread.new do
                info.on_finish(stud, args_h)
              end
            end
            fx_tracker.synth_finished([sn, group_id]) if fx_tracker
            tl_tracker.synth_finished([sn, group_id]) if tl_tracker
          end
        end

        s = nil
        __no_kill_block do

          info.on_start(@mod_sound_studio, args_h) if info

        s = @mod_sound_studio.trigger_live_synth live_id, synth_name, group, args_h, info, now, t_minus_delta, pos, pre_trig_blk, on_move_blk

        __thread_locals.set(:sonic_pi_local_last_triggered_node, s)
        end
        s

      end

      def add_out_bus_and_rand_buf!(args_h, out_bus=nil, info=nil)
        out_bus = current_out_bus unless out_bus
        args_h["out_bus"] = out_bus.to_i
      end

      def calculate_sustain!(args)
        if args.has_key? :duration and not(args.has_key? :sustain)
          attack = (args.fetch(:attack, 0)  || args.fetch(:atk, 0))
          decay = args.fetch(:decay, 0)     || args.fetch(:dec, 0)
          release = args.fetch(:release, 0) || args.fetch(:rel, 0)
          duration = args[:duration]

          sustain = duration - (attack + decay + release)
          args[:sustain] = [0, sustain].max
          args.delete :duration
        end
      end

      def normalise_and_resolve_sample_args(path, args_h, info, combine_tls=false)
        purge_nil_vals!(args_h)
        defaults = info ? info.arg_defaults : {}
        t_l_args = __thread_locals.get(:sonic_pi_mod_sound_sample_defaults) || {}
        t_l_args.each do |k, v|
          args_h[k] = v unless args_h.has_key? k || v.nil?
        end

        stretch_duration = args_h[:beat_stretch]
        if stretch_duration
          raise "beat_stretch: opt needs to be a positive number. Got: #{stretch_duration.inspect}" unless stretch_duration.is_a?(Numeric) && stretch_duration > 0
          stretch_duration = stretch_duration.to_f
          rate = args_h[:rate] || 1
          dur = sample_buffer(path).duration
          args_h[:rate] = (1.0 / stretch_duration) * rate * (current_bpm / (60.0 / dur))
        end

        pitch_stretch_duration = args_h[:pitch_stretch]
        if pitch_stretch_duration
          raise "pitch_stretch: opt needs to be a positive number. Got: #{pitch_stretch_duration.inspect}" unless pitch_stretch_duration.is_a?(Numeric) && pitch_stretch_duration > 0
          pitch_stretch_duration = pitch_stretch_duration.to_f
          rate = args_h[:rate] || 1
          dur = sample_buffer(path).duration
          new_rate = (1.0 / pitch_stretch_duration) * (current_bpm / (60.0 / dur))
          pitch_shift = ratio_to_pitch(new_rate)
          args_h[:rate] = new_rate * rate
          args_h[:pitch] = args_h[:pitch].to_f - pitch_shift
        end

        rate_pitch = args_h[:rpitch]
        if rate_pitch
          new_rate = pitch_to_ratio(rate_pitch.to_f)
          args_h[:rate] = new_rate * (args_h[:rate] || 1)
        end

        slice_idx = args_h[:slice]
        if slice_idx
          num_slices = args_h.fetch(:num_slices, 16).round
          raise "Sample opt num_slices: needs to be greater than 0. Got: #{num_slices}" unless num_slices.is_a?(Numeric) && num_slices > 0
          slices = sample_buffer(path).slices(num_slices)
          if slice_idx.is_a? Numeric
            slice_idx = slice_idx.round
            slice = slices[slice_idx]
          elsif slice_idx.is_a? Proc
            slice = slice_idx.call(slices)
            slice = slice[0] if is_list_like?(slice)
            raise "Result of slice: proc should be a Map such as {:start => 0, :finish => 0.125}. Got: #{slice.inspect}" unless slice.respond_to?(:has_key?) && slice[:start].is_a?(Numeric) && slice[:finish].is_a?(Numeric)
          else
            raise "Unknown sample slice: value. Expected a number or a proc. Got #{slice_idx.inspect}"
          end
          args_h[:start] = slice[:start]
          args_h[:finish] = slice[:finish]
          args_h[:slice] = slice[:index] if slice[:index]
        end

        onset_idx = args_h[:onset]
        if onset_idx
          begin
            onsets = sample_buffer(path).onset_slices
          rescue Exception => e
            if (os == :windows) && sample_buffer(path).sample_rate != 44100
              raise "Sorry, on Windows, onset detection only currently works with audio files that have a sample rate of 44100. Your sample has a rate of: #{sample_buffer(path).sample_rate}"
            else
              raise "Unable to find onset for sample with path #{path}:\n#{e.message}\n#{e.backtrace}"
            end
          end

          if onset_idx.is_a? Numeric
            onset_idx = onset_idx.round
            args_h.merge!(onsets[onset_idx])
            res = onsets[onset_idx]
          elsif onset_idx.is_a? Proc
            res = onset_idx.call(onsets)
            res = res[0] if is_list_like?(res)
            raise "Result of onset: proc should be a Map such as {:start => 0, :finish => 0.125}. Got: #{res.inspect}" unless res.respond_to?(:has_key?) && res[:start].is_a?(Numeric) && res[:finish].is_a?(Numeric)

          else
            raise "Unknown sample onset: value. Expected a number or a proc. Got #{onset_idx.inspect}"
          end
          args_h[:start] = res[:start]
          args_h[:finish] = res[:finish]
          args_h[:onset] = res[:index] if res[:index]
        end

        if info
          args_h = info.munge_opts(@mod_sound_studio, args_h)
          resolve_midi_args!(args_h, info)
          resolve_buffer_args!(args_h, info)
        end

        normalise_args!(args_h, defaults)
        scale_time_args_to_bpm!(args_h, info, true) if info && __thread_locals.get(:sonic_pi_spider_arg_bpm_scaling)
        args_h
      end



      def normalise_and_resolve_synth_args(args_h, info, combine_tls=false)
        purge_nil_vals!(args_h)
        defaults = info ? info.arg_defaults : {}
        if combine_tls
          t_l_args = __thread_locals.get(:sonic_pi_mod_sound_synth_defaults) || {}
          t_l_args.each do |k, v|
            args_h[k] = v unless args_h.has_key? k || v.nil?
          end
        end


        if info
          args_h = info.munge_opts(@mod_sound_studio, args_h)
          resolve_midi_args!(args_h, info)
          resolve_buffer_args!(args_h, info)
        end

        normalise_args!(args_h, defaults)
        calculate_sustain!(args_h)
        scale_time_args_to_bpm!(args_h, info, true) if info && __thread_locals.get(:sonic_pi_spider_arg_bpm_scaling)

        args_h
      end

      def current_job_id
        __system_thread_locals.get :sonic_pi_spider_job_id
      end

      def current_job_mixer
        job_mixer(current_job_id)
      end


      def current_group
        if g = __system_thread_locals.get(:sonic_pi_mod_sound_job_group)
          return g
        else
          g = default_job_synth_group(current_job_id)
          __system_thread_locals.set :sonic_pi_mod_sound_job_group, g
          return g
        end
      end

      def default_job_synth_group(job_id)
        g = @JOB_GROUPS_A.deref[job_id]
        return g if g

        @JOB_GROUP_MUTEX.synchronize do
          g = @JOB_GROUPS_A.deref[job_id]
          return g if g
          g = @mod_sound_studio.new_synth_group(job_id)

          @JOB_GROUPS_A.swap! do |gs|
            gs.put job_id, g
          end
        end
        g
      end



      def current_out_bus
        current_bus = __system_thread_locals.get(:sonic_pi_mod_sound_synth_out_bus)
        current_bus || current_job_bus
      end

      def current_job_bus
        job_bus(current_job_id)
      end

      def job_bus(job_id)
        b = @JOB_BUSSES_A.deref[job_id]
        return b if b

        new_bus = nil

        @JOB_BUSSES_MUTEX.synchronize do
          b = @JOB_BUSSES_A.deref[job_id]
          return b if b

          begin
            new_bus = @mod_sound_studio.new_fx_bus
          rescue AllocationError
            raise "All busses allocated - unable to create audio bus for job"
          end

          @JOB_BUSSES_A.swap! do |gs|
            gs.put job_id, new_bus
          end
        end
        ## ensure job mixer has started
        job_mixer(job_id)
        return new_bus
      end

      def job_mixer(job_id)
        m = @JOB_MIXERS_A.deref[job_id]
        return m if m

        @JOB_MIXERS_MUTEX.synchronize do
          m = @JOB_MIXERS_A.deref[job_id]
          return m if m

          args_h = {
            "in_bus" => job_bus(job_id).to_i,
            "amp" => 0.3
          }

          sn = "basic_mixer"
          info = Synths::SynthInfo.get_info(sn)
          defaults = info.arg_defaults
          synth_name = info.scsynth_name

          combined_args = defaults.merge(args_h)
          combined_args["out_bus"] = @mod_sound_studio.mixer_bus.to_i

          validate_if_necessary! info, combined_args

          group = @mod_sound_studio.mixer_group

          n = @mod_sound_studio.trigger_synth synth_name, group, combined_args, info, true, false, :head

          mix_n = ChainNode.new(n)

          @JOB_MIXERS_A.swap! do |gs|
            gs.put job_id, mix_n
          end

          return mix_n
        end
      end


      def free_job_bus(job_id)
        old_job_busses = @JOB_BUSSES_A.swap_returning_old! do |js|
          js.delete job_id
        end
        bus = old_job_busses[job_id]
        bus.free if bus
      end

      def shutdown_job_mixer(job_id)
        old_job_mixers = @JOB_MIXERS_A.swap_returning_old! do |js|
          js.delete job_id
        end
        mixer = old_job_mixers[job_id]
        fade_out_time = 1
        if mixer
          mixer.ctl_now amp_slide: fade_out_time
          Kernel.sleep 0.1
          mixer.ctl_now amp: 0
          Kernel.sleep fade_out_time
          mixer.kill(true)
        else
          # Mixer must have already been asked to shutdown.
          # Block this thread for a longer amount of time
          # to make sure it doesn't overtake the first thread
          # and kill the group if called from a hook call..
          Kernel.sleep fade_out_time + 0.5
        end

      end

      def kill_job_group(job_id)
        old_job_groups = @JOB_GROUPS_A.swap_returning_old! do |js|
          js.delete job_id
        end

        job_group = old_job_groups[job_id]
        job_group.kill(true) if job_group

      end

      def join_thread_and_subthreads(t)
        t.join
        subthreads = __system_thread_locals(t).get :sonic_pi_local_spider_subthreads
        subthreads.each do |st|
          join_thread_and_subthreads(st)
        end
      end

      def validate_if_necessary!(info, args_h)
        if info &&
            __thread_locals.get(:sonic_pi_mod_sound_check_synth_args)
          info.validate!(args_h)
        end
      end

      def ensure_good_timing!
        return true if __thread_locals.get(:sonic_pi_mod_sound_disable_timing_warnings)
        raise "Timing Exception: thread got too far behind time." if time_diff > 1.1
      end

      def time_diff
        # negative values mean we're ahead of time
        # positive values mean we're behind time
        vt  = __system_thread_locals.get :sonic_pi_spider_time
        sat = current_sched_ahead_time
        compensated = (Time.now - sat)
        compensated - vt
      end

      def in_good_time?(error_window=0)
        diff = time_diff
        if diff < error_window
          return true
        else
          if diff < 1.1
            return false
          else
            raise "Timing Exception: thread got too far behind time."
          end
        end
      end

      def current_synth_name
        __thread_locals.get(:sonic_pi_mod_sound_current_synth_name) ||
        __thread_locals.set(:sonic_pi_mod_sound_current_synth_name, :beep)
      end

      def set_current_synth(name)
        __thread_locals.set(:sonic_pi_mod_sound_current_synth_name, name)
      end

      def scale_time_args_to_bpm!(args_h, info, force_add = true)
        # some of the args in args_h need to be scaled to match the
        # current bpm. Check in info to see if that's necessary and if
        # so, scale them.
        args_h = args_h.to_h
        new_args = {}
        if force_add
          defaults = info.arg_defaults
          # force_add is true so we need to ensure that we scale args
          # that haven't been explicitly passed as the synth arg
          # defaults have no idea of BPM.
          info.bpm_scale_args.each do |arg_name|
            val = args_h[arg_name] || defaults[arg_name]
            # perform a lookup in defaults if necessary
            # allows defaults to be keys one level deep
            # see .normalise_args!
            val = (args_h[val] || defaults[val]) if val.is_a?(Symbol)
            scaled_val = val * __system_thread_locals.get(:sonic_pi_spider_sleep_mul)
            new_args[arg_name] = scaled_val unless scaled_val == defaults[arg_name]

          end
        else
          # only scale the args that have been passed.
          info.bpm_scale_args.each do |arg_name, default|
            new_args[arg_name] = args_h[arg_name] * __system_thread_locals.get(:sonic_pi_spider_sleep_mul) if args_h.has_key?(arg_name)

          end
        end
        args_h.merge!(new_args)
      end

      def resolve_midi_args!(args_h, info)
        info.midi_args.each do |arg_name|
          if args_h.has_key? arg_name
            args_h[arg_name] = note(args_h[arg_name])
          end
        end
        args_h
      end

      def resolve_buffer_args!(args_h, info)
        info.buffer_args.each do |arg_name|
          if args_h.has_key? arg_name
            buffer_opt = args_h[arg_name]

            case buffer_opt
            when Buffer
              # do nothing
            when String, Symbol
              buf = buffer(buffer_opt)
              raise "Unable to initialise buffer #{buffer_opt.inspect}" unless buf
              args_h[:buffer] = buf
            when Array, SonicPi::Core::SPVector
              raise "buffer: opt should only contain 2 elements. You supplied: #{buf.size} - #{buf.inspect}" unless buffer_opt.size == 2
              buf = buffer(*buffer_opt)
              raise "Unable to initialise buffer #{buffer_opt.inspect}" unless buf
              args_h[:buffer] = buf

            else
              raise "Unknown value for buffer: opt - #{buf.inspect}. Expected one of :foo, \"foo\" or [:foo, 3]"
            end
          end
        end
        args_h
      end

      def add_arg_slide_times!(args_h, info)
        default_slide_time = args_h[:slide]
        if info && default_slide_time
          info.slide_args.each do |k|
            args_h[k] = default_slide_time unless args_h.has_key?(k)
          end
        end
        args_h
      end

      def normalise_tuning(n)
        if tuning_info = __thread_locals.get(:sonic_pi_mod_sound_tuning)
          tuning_system, fundamental_sym = tuning_info
          if tuning_system != :equal
            return @tuning.resolve_tuning(n, tuning_system, fundamental_sym)
          end
        end
        n
      end

      def normalise_transpose_and_tune_note_from_args(n, args_h)
        n = n || args_h[:note]

        n = n.call if n.is_a? Proc
        n = n[0] if is_list_like?(n) && n.size == 1
        n = note(n) unless n.is_a? Numeric

        if shift = __thread_locals.get(:sonic_pi_mod_sound_transpose)
          n += shift
        end

        if octave_shift = __thread_locals.get(:sonic_pi_mod_sound_octave_shift)
          n += (12 * octave_shift)
        end

        if cent_shift = __thread_locals.get(:sonic_pi_mod_sound_cent_tuning)
          n += (cent_shift / 100.0)
        end

        if instance_variable_defined?(:@mod_sound_studio)
          n += (@mod_sound_studio.cent_tuning / 100.0)
        end

        n += args_h[:pitch].to_f

        n = normalise_tuning(n)
        return n
      end

      def sample_find_candidates(*args)
        @sample_loader.find_candidates(*args)
      end

      def _
        nil
      end

    end

  end
end
