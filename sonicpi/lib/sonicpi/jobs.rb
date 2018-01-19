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
require_relative "counter"
require_relative 'atom'
require 'thread'

require 'hamster/hash'

module SonicPi
  class Jobs

    def initialize
      @jobs_A = Atom.new(Hamster::Hash.new)
    end

    def add_job(id, job, info)
      @jobs_A.swap! do |js|
        js.put(id, {:job => job, :info => info})
      end
    end

    def job_completed(id)
      @jobs_A.swap! do |js|
        js.delete id
      end
    end

    def kill_job(id)
      old = @jobs_A.swap_returning_old! do |js|
        js.delete id
      end

      job = old[id]
      if job
        __system_thread_locals(job[:job]).get(:sonic_pi_local_spider_no_kill_mutex).synchronize do
          job[:job].kill
        end
      end
    end

    def running?(id)
      @jobs_A.deref[id]
    end

    def each_id(&block)
      @jobs_A.deref.keys.each(&block)
    end

    def any_jobs_running?
      !@jobs_A.deref.empty?
    end
  end
end
