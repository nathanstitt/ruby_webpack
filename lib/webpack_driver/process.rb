require 'concurrent/array'
require 'concurrent/map'
require 'childprocess'
require 'json'

module WebpackDriver

    class Process
        READ_CHUNK_SIZE = 1024

        extend Forwardable

        def_delegators :@proc, :alive?, :environment, :wait

        attr_reader :config, :assets, :messages, :progress, :error,
                    :last_compilation_message, :last_status

        def initialize(script, config)
            self.reset!
            @config = config
            args = ["./node_modules/.bin/#{script}"] + config.flags
            config.logger.info("Starting webpack using command:\n#{args.join(' ')}")
            @proc = ::ChildProcess.build(*args)

            @proc.environment.merge!(
                config.environment
            )
            if config.directory
                config.logger.info("In directory: #{config.directory}")
                @proc.cwd = config.directory
            end
        end

        def start
            self.reset!
            @output, w = IO.pipe
            @proc.io.stdout = @proc.io.stderr = w
            @proc.start
            w.close
            @listener = listen_for_status_updates
        end

        def stop
            @proc.stop
            @output.close unless @output.closed?
            @listener.join
        end

        def in_progress?
            !@error && @progress && @progress != 1
        end

        protected

        def reset!
            @assets = Concurrent::Map.new
            @messages = Concurrent::Array.new
            @last_compilation_message = {}
        end

        def record_error(error)
            @error = error
            config.logger.error(
                "#{error['name']}: #{error['resource']}\n#{error['message']}"
            )
        end

        def record_progress(progress, msg)
            @progress = progress
            @last_compilation_message = msg['value']
        end

        def record_message(msg)
            @messages << msg unless msg['type'] == 'progress'
            case msg['type']
            when 'status'
                @last_status = msg['value']
            when 'asset'
                Asset.record(@assets, msg['value'])
            when 'compile'
                record_progress msg['value']['progress'], msg
            when 'error'
                record_error(msg['value'])
            when 'config'
                config.output_path = Pathname.new(msg['value']['output_path'])
            else
                config.logger.debug(msg)
            end
        end


        def listen_for_status_updates
            Thread.new do
                @output.each_line do | l |
                    begin
                        match = l.match(/^STATUS: (.*)/)
                        if match
                            record_message(JSON.parse(match[1]))
                            config.logger.debug(l.chomp)
                        else
                            config.logger.info(l.chomp)
                        end
                    rescue => e
                        config.logger.error "Exception #{e} encountered while processing line #{l}"
                    end
                end
            end
        end

    end
end
