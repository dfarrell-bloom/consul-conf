
require_relative 'consul-conf/ServiceBackends.rb'

require 'tempfile'
require 'shellwords'
require 'erubis'
require 'English' # for CHILD_STATUS

class ConsulConf
  attr_reader :config

  class ConsulConfException < Exception
  end
  class InitError < ConsulConfException
  end
  class ConfigError < ConsulConfException
  end

  def initialize(log, configfile)
    fail InitError.new "log should be of type Logger!  I got a #{log.class.name}." unless log.is_a? Logger
    @log = log
    begin
      @config = JSON.parse File.read(configfile)
  rescue Errno::ENOENT => e
    raise InitError.new "Failed to open config file #{configfile}: #{e.message}"
  rescue JSON::ParserError => e
    raise InitError.new "Failed to parse config file #{configfile} as json.  Contained: '#{File.read configfile}\n'"
    end
    checkConfig
    begin
     @template = Erubis::Eruby.new(File.read @config['template'])
 rescue Errno::ENOENT => e
   raise InitError.new "Failed to load ERB template file #{@config['template']}: #{e.message}"
   end
    @backends = ServiceBackends.new @config, @log
  end

  def checkConfigOption(opt)
    @config.key? opt
  end

  def checkConfig
    missing = []
    %w(template outfile).each do |opt|
      missing << opt unless checkConfigOption opt
    end
    if checkConfigOption 'comment_regex' # perhaps /^\s*#/
      @config['comment_regex'] = Regexp.new @config['comment_regex']
    end
    if checkConfigOption 'postupdate'
      if checkConfigOption 'postupdate_status'
        # use the shell to check
        system("exit #{@config['postupdate_status'].to_i} ")
        postupdate_status = $CHILD_STATUS.exitstatus
        if postupdate_status != @config['postupdate_status']
          @log.warn("Configuration option 'postupdate_status' out of range " \
              '( exit status is 8 bit unsigned integer ).  ' \
              "#{@config['postupdate_status']} will never be an exit status"
          )
        end
      else
        @config['postupdate_status'] = 0  # a very sane default
      end
    end
    if missing.count > 0
      fail ConfigError.new('Required Configuration options unspecified: ' +
          missing.join(' '))
    end
    @log.debug "Loaded configuration options: #{@config.inspect}"
  end

  def render
    @template.result(:services => @backends.allServiceBackends)
  end

  def remove_comments(content)
    if @config.key? 'comment_regex'
      content.lines.reject { |l| l =~ @config['comment_regex'] }.join('')
    else
      content
    end
  end

  # return true if files are different
  def diff(file1, file2)
    diffcmd = "diff #{Shellwords.escape file1} #{Shellwords.escape file2}"
    @log.debug "Executing diff command: #{diffcmd}"
    system(diffcmd)
    exitstatus = $CHILD_STATUS.exitstatus
    if exitstatus == 0
      return false
    elsif exitstatus == 1
      return true
    else
      @log.error("Diff appears to have failed: unexpected return status #{exitstatus}" \
          '(it is assumed that the files are different)')
      return true
    end
  end

  def outdated?(newdata)
    return true unless File.exist? @config['outfile']
    outdated = true
    begin
      oldtmp = Tempfile.new(File.expand_path(@config['outfile']) + '_old')
      newtmp = Tempfile.new(File.expand_path(@config['outfile']) + '_new')
      olddata = File.read(File.expand_path @config['outfile'])
      # if configured, remove comments from the files
      newdata = remove_comments newdata
      olddata = remove_comments olddata
      # sync files so we can call diff against
      oldtmp.write olddata
      oldtmp.fsync
      newtmp.write newdata
      newtmp.fsync
      outdated = diff(oldtmp.path, newtmp.path)
  ensure
    oldtmp.close
    oldtmp.unlink
    newtmp.close
    newtmp.unlink
    end
    outdated
  end

  # execute an update
  def update!(new_content)
    File.open(File.expand_path(@config['outfile']), 'w') { |f|
      f.write new_content
    }
    postupdate
  end

  def postupdate
    if checkConfigOption 'postupdate'
      @log.debug "Executing postupdate: #{@config['postupdate']}"
      system(@config['postupdate'])
      exitstatus = $CHILD_STATUS.exitstatus
      @log.debug "Post update returned #{exitstatus}"
      if $CHILD_STATUS.exitstatus != @config['postupdate_status']
        @log.error(
            'Postupdate command appears to have failed.  ' \
            "Exit status expected: #{@config['postupdate_status']}, " \
            "got: #{exitstatus}"
        )
        return false
      end
    end
    return true
  end

  # update only if we're outdated
  def update
    new_content = render
    if outdated? new_content
      @log.info "#{@config['outfile']} needs an update."
      res = update! new_content
    else
      @log.info "#{@config['outfile']} is already up to date, no update required"
      res = true
    end
    return res
  end
end
