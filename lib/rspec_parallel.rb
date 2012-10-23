#encoding: UTF-8
$LOAD_PATH << File.dirname(__FILE__)
require 'progressbar'
require 'color_helper'
require 'thread'
include ColorHelpers

class Rspec_parallel
  def initialize(thread_number, case_folder, filter_options = {}, env_list = [], show_pending = false)
    @thread_number = thread_number
    if thread_number < 1
      puts red("threads_number can't be less than 1")
      return
    end
    @case_folder = case_folder
    @filter_options = filter_options
    @env_list = env_list
    @show_pending = show_pending
    @queue = Queue.new
  end

  def run_tests()
    # use lock to avoid output mess up
    @lock = Mutex.new
    # timer of rspec task
    start_time = Time.now

    puts yellow("threads number: #{@thread_number}\n")
    parse_case_list

    pbar = ProgressBar.new("0/#{@queue.size}", @queue.size, $stdout)
    pbar.format_arguments = [:title, :percentage, :bar, :stat]
    case_number = 0
    failure_number = 0
    pending_number = 0
    failure_list = []
    pending_list = []

    Thread.abort_on_exception = false
    threads = []

    @thread_number.times do |i|
      threads << Thread.new do
        until @queue.empty?
          task = @queue.pop
          env_extras = {}
          if @env_list && @env_list[i]
            env_extras = @env_list[i]
          end
          task_output = run_task(task, env_extras)

          if task_output =~ /Failures/ || task_output =~ /0 examples/
            @lock.synchronize do
              failure_number += 1
              failure_log = parse_failure_log(task_output)
              failure_list << [task, failure_log]

              # print failure immediately during the execution
              $stdout.print "\e[K"
              if failure_number == 1
                puts "Failures:"
              end
              puts "  #{failure_number}) #{failure_log}\n"
              puts red("     (Failure time: #{Time.now})\n\n")
            end
          elsif task_output =~ /Pending/
            @lock.synchronize do
              pending_number += 1
              pending_list << [task, parse_pending_log(task_output)]
            end
          end
          case_number += 1
          pbar.inc
          pbar.instance_variable_set("@title", "#{pbar.current}/#{pbar.total}")
        end
      end
      # ramp up user threads one by one
      sleep 0.1
    end

    threads.each { |t| t.join }
    pbar.finish

    # print pending cases if configured
    $stdout.print "\n"
    if @show_pending && pending_number > 0
      puts "Pending:"
      pending_list.each {|p|
        puts "  #{p[1]}\n"
      }
    end
    $stdout.print "\n"
    t2 = Time.now
    puts green("Finished in #{format_time(t2-start_time)}\n")
    if failure_number > 0
      $stdout.print red("#{case_number} examples, #{failure_number} failures")
      $stdout.print red(", #{pending_number} pending") if pending_number > 0
    else
      $stdout.print yellow("#{case_number} examples, #{failure_number} failures")
      $stdout.print yellow(", #{pending_number} pending") if pending_number > 0
    end
    $stdout.print "\n"

    # record failed rspec examples to rerun.sh
    unless failure_list.empty?
      rerun_file = File.new('./rerun.sh', 'w', 0777)
      $stdout.print "\nFailed examples:\n\n"
      failure_list.each_with_index do |log, i|
        case_desc = ''
        log[1].each_line {|line|
          case_desc = line
          break
        }

        rerun_cmd = 'rspec .' + log[0].match(/\/spec\/.*_spec\.rb:\d{1,4}/).to_s
        rerun_file.puts "echo ----#{case_desc}"
        rerun_file.puts rerun_cmd + " # #{case_desc}"
        $stdout.print red(rerun_cmd)
        $stdout.print cyan(" # #{case_desc}")
      end
      rerun_file.close
      $stdout.print "\n"
    end
  end

  def get_case_list
    file_list = `grep -rl '' #{@case_folder}`
    case_list = []
    file_list.each_line { |filename|
      unless filename.include? "_spec.rb"
        next
      end
      f = File.read(filename.strip).force_encoding("ISO-8859-1").encode("utf-8", replace: nil)

      # try to get tags of describe level
      describe_text = f.scan(/describe [\s\S]*? do/)[0]
      describe_tags = []
      temp = describe_text.scan(/[,\s]:(\w+)/)
      unless temp == nil
        temp.each do |t|
          describe_tags << t[0]
        end
      end

      # get cases of normal format: "it ... do"
      cases = f.scan(/(it (["'])([\s\S]*?)\2[\s\S]*? do)/)
      line_number = 0
      if cases
        cases.each { |c1|
          c = c1[0]
          tags = []
          draft_tags = c.scan(/[,\s]:(\w+)/)
          draft_tags.each { |tag|
            tags << tag[0]
          }
          tags += describe_tags
          tags.uniq

          i = 0
          cross_line = false
          f.each_line { |line|
            i += 1
            if i <= line_number && line_number > 0
              next
            end
            if line.include? c1[2]
              if line.strip.end_with? " do"
                case_hash = {"line" => "#{filename.strip}:#{i}", "tags" => tags}
                case_list << case_hash
                line_number = i
                cross_line = false
                break
              else
                cross_line = true
              end
            end
            if cross_line && (line.strip.end_with? " do")
              case_hash = {"line" => "#{filename.strip}:#{i}", "tags" => tags}
              case_list << case_hash
              line_number = i
              cross_line = false
              break
            end
          }
        }
      end

      # get cases of another format: "it {...}"
      cases = f.scan(/it \{[\s\S]*?\}/)
      line_number = 0
      if cases
        cases.each { |c|
          i = 0
          f.each_line { |line|
            i += 1
            if i <= line_number && line_number > 0
              next
            end
            if line.include? c
              case_hash = {"line" => "#{filename.strip}:#{i}", "tags" => describe_tags}
              case_list << case_hash
              line_number = i
              break
            end
          }
        }
      end
    }
    case_list
  end

  def parse_case_list()
    all_case_list = get_case_list
    pattern_filter_list = []
    tags_filter_list = []

    if @filter_options["pattern"]
      all_case_list.each { |c|
        if c["line"].match(@filter_options["pattern"])
          pattern_filter_list << c
        end
      }
    else
      pattern_filter_list = all_case_list
    end

    if @filter_options["tags"]
      include_tags = []
      exclude_tags = []
      all_tags = @filter_options["tags"].split(",")
      all_tags.each { |tag|
        if tag.start_with? "~"
          exclude_tags << tag.gsub("~", "")
        else
          include_tags << tag
        end
      }
      pattern_filter_list.each { |c|
        if (include_tags.length == 0 || (c["tags"] - include_tags).length < c["tags"].length) &&
            ((c["tags"] - exclude_tags).length == c["tags"].length)
          tags_filter_list << c
        end
      }
    else
      tags_filter_list = pattern_filter_list
    end

    tags_filter_list.each { |t|
      @queue << t["line"]
    }
  end

  def run_task(task, env_extras)
    cmd = [] # Preparing command for popen
    cmd << ENV.to_hash.merge(env_extras)
    cmd += ["bundle", "exec", "rspec", "--color", task]
    cmd

    output = ""
    IO.popen(cmd, :err => [:child, :out]) do |io|
      output << io.read
    end

    output
  end

  def format_time(t)
    time_str = ''
    time_str += (t / 3600).to_i.to_s + " hours " if t > 3600
    time_str += (t % 3600 / 60).to_i.to_s + " minutes " if t > 60
    time_str += (t % 60).to_f.round(2).to_s + " seconds"
    time_str
  end

  def parse_failure_log(str)
    return str if str =~ /0 examples/
    index1 = str.index('1) ')
    index2 = str.index('Finished in')
    output = ""
    temp = str.slice(index1+3..index2-1).strip
    first_line = true
    temp.each_line { |line|
      if first_line
        output += line
      elsif line.strip.start_with? "# "
        output += cyan(line)
      else
        output += red(line)
      end
      first_line = false
    }
    output
  end

  def parse_pending_log(str)
    index1 = str.index('Pending:')
    index2 = str.index('Finished in')
    output = ""
    temp = str.slice(index1+8..index2-1).strip
    first_line = true
    temp.each_line { |line|
      if first_line
        output += yellow(line)
      elsif line.strip.start_with? "# "
        output += cyan(line)
      else
        output += line
      end
      first_line = false
    }
    output
  end
end
