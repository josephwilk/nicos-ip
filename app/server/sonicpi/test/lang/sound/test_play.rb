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

require_relative "../../setup_test"
require_relative "../../../lib/sonicpi/atom"
require_relative "../../../lib/sonicpi/lang/core"
require_relative "../../../lib/sonicpi/lang/sound"
require 'mocha/setup'
require 'ostruct'

module SonicPi
  class PlayTester < Minitest::Test
    def setup
      @mock_sound = Object.new
      @mock_sound.extend(Lang::Sound)
      @mock_sound.extend(Lang::Core)
      @mock_sound.stubs(:sleep) # avoid loading Spider class
      @mock_sound.stubs(:ensure_good_timing!) # avoid loading Spider class
      @mock_sound.stubs(:__delayed_user_message)
      @mock_sound.stubs(:current_synth_name).returns(:beep)
      @mock_sound.send(:init_tuning)
      @beep_info = Synths::SynthInfo.get_info(:beep)
    end

    def test_play_with_various_args
      @mock_sound.reset
      @mock_sound.expects(:trigger_inst).with(:beep, {note: 60.0}, @beep_info)
      @mock_sound.play :c

      @mock_sound.expects(:trigger_inst).with(:beep, {note: 60.0, release: 0.1}, @beep_info)
      @mock_sound.play :c, release: 0.1

      # Single hash
      @mock_sound.expects(:trigger_inst).with(:beep, {note: 60, release: 0.1}, @beep_info)
      @mock_sound.play({note: :c, release: 0.1})

      # nils are culled (but only prior to encoding as an OSC message)
      @mock_sound.expects(:trigger_inst).with(:beep, {note: 60, cutoff: nil}, @beep_info)
      @mock_sound.play({note: :c, cutoff: nil})
    end

    def test_multi_notes
      @mock_sound.reset
      @mock_sound.expects(:trigger_chord).with(:beep, [62.0], {})
      @mock_sound.play [62]
    end

    def test_note_with_tuning
      @mock_sound.reset
      @mock_sound.expects(:trigger_inst).with(:beep, {note: 62.039100017}, @beep_info)
      @mock_sound.with_tuning :just do
        @mock_sound.play 62
      end
    end

    def test_chord_with_tuning
      @mock_sound.reset
      @mock_sound.expects(:trigger_chord).with(:beep, [62.039100017], {})
      @mock_sound.with_tuning :just do
        @mock_sound.play [62]
      end
    end

    def test_play_chord_with_tuning
      @mock_sound.reset
      @mock_sound.expects(:trigger_chord).with(:beep, [62.039100017], {})
      @mock_sound.with_tuning :just do
        @mock_sound.play_chord [62]
      end
    end

    def test_play_and_use_synth_defaults
      @mock_sound.reset
      @mock_sound.use_synth_defaults release: 0.3
      @mock_sound.expects(:trigger_inst).with(:beep, {note: 60.0, release: 0.3}, @beep_info)
      @mock_sound.play 60

      @mock_sound.expects(:trigger_inst).with(:beep, {note: 61.0, release: 0.3}, @beep_info)
      @mock_sound.play 61

      @mock_sound.expects(:trigger_inst).with(:beep, {note: 61.0, release: 0.5}, @beep_info)
      @mock_sound.play 61, release: 0.5
    end

    def test_play_and_with_synth_defaults
      @mock_sound.reset

      @mock_sound.expects(:trigger_inst).with(:beep, {note: 60.0, release: 0.3}, @beep_info)
      @mock_sound.with_synth_defaults release: 0.3 do
        @mock_sound.play 60
      end

      @mock_sound.expects(:trigger_inst).with(:beep, {note: 61.0, release: 0.3}, @beep_info)
      @mock_sound.with_synth_defaults release: 0.3 do
        @mock_sound.play 61
      end

      @mock_sound.expects(:trigger_inst).with(:beep, {note: 61.0, release: 0.5}, @beep_info)
      @mock_sound.with_synth_defaults release: 0.5 do
        @mock_sound.play 61, release: 0.5
      end
    end
  end
end
