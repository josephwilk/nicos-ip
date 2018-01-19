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
require_relative "busallocator"
require_relative "audiobus"

module SonicPi
  class AudioBusAllocator < BusAllocator
    def bus_class
      AudioBus
    end

    def allocation_size
      2
    end

    def to_s
      "<#SonicPi::AudioBusAllocator>"
    end
  end
end
