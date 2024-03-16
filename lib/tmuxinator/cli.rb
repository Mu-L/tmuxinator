require "open3"

module Tmuxinator
  class Cli < Thor
    # By default, Thor returns exit(0) when an error occurs.
    # Please see: https://github.com/tmuxinator/tmuxinator/issues/192
    def self.exit_on_failure?
      true
    end

    include Tmuxinator::Util

    COMMANDS = {
      commands: "Lists commands available in tmuxinator",
      completions: "Used for shell completion",
      new: "Create a new project file and open it in your editor",
      edit: "Alias of new",
      open: "Alias of new",
      start: %w{
        Start a tmux session using a project's name (with an optional [ALIAS]
        for project reuse) or a path to a project config file (via the -p flag)
      }.join(" "),
      stop: "Stop a tmux session using a project's tmuxinator config",
      local: "Start a tmux session using ./.tmuxinator.y[a]ml",
      debug: "Output the shell commands that are generated by tmuxinator",
      copy: %w{
        Copy an existing project to a new project and
        open it in your editor
      }.join(" "),
      delete: "Deletes given project",
      implode: "Deletes all tmuxinator projects",
      version: "Display installed tmuxinator version",
      doctor: "Look for problems in your configuration",
      list: "Lists all tmuxinator projects"
    }.freeze

    # For future reference: due to how tmuxinator currently consumes
    # command-line arguments (see ::bootstrap, below), invocations of Thor's
    # base commands (i.e. 'help', etc) can be instead routed to #start (rather
    # than to ::start).  In order to prevent this, the THOR_COMMANDS and
    # RESERVED_COMMANDS constants have been introduced. The former enumerates
    # any/all Thor commands we want to insure get passed through to Thor.start.
    # The latter is the superset of the Thor commands and any tmuxinator
    # commands, defined in COMMANDS, above.
    THOR_COMMANDS = %w[-v help].freeze
    RESERVED_COMMANDS = (COMMANDS.keys + THOR_COMMANDS).map(&:to_s).freeze

    package_name "tmuxinator" \
      unless Gem::Version.create(Thor::VERSION) < Gem::Version.create("0.18")

    desc "commands", COMMANDS[:commands]

    def commands(shell = nil)
      out = if shell == "zsh"
              COMMANDS.map do |command, desc|
                "#{command}:#{desc}"
              end.join("\n")
            else
              COMMANDS.keys.join("\n")
            end

      say out
    end

    desc "completions [arg1 arg2]", COMMANDS[:completions]

    def completions(arg)
      if %w(start stop edit open copy delete).include?(arg)
        configs = Tmuxinator::Config.configs
        say configs.join("\n")
      end
    end

    desc "new [PROJECT] [SESSION]", COMMANDS[:new]
    map "open" => :new
    map "edit" => :new
    map "o" => :new
    map "e" => :new
    map "n" => :new
    method_option :local, type: :boolean,
                          aliases: ["-l"],
                          desc: "Create local project file at ./.tmuxinator.yml"

    def new(name, session = nil)
      if session
        new_project_with_session(name, session)
      else
        new_project(name)
      end
    end

    no_commands do
      def new_project(name)
        project_file = find_project_file(name, options[:local])
        Kernel.system("$EDITOR #{project_file}") || doctor
      end

      def new_project_with_session(name, session)
        if Tmuxinator::Config.version < 1.6
          raise "Creating projects from sessions is unsupported\
            for tmux version 1.5 or lower."
        end

        windows, _, s0 = Open3.capture3(<<-CMD)
          tmux list-windows -t #{session}\
          -F "#W \#{window_layout} \#{window_active} \#{pane_current_path}"
        CMD
        panes, _, s1 = Open3.capture3(<<-CMD)
          tmux list-panes -s -t #{session} -F "#W \#{pane_current_path}"
        CMD
        tmux_options, _, s2 = Open3.capture3(<<-CMD)
          tmux show-options -t #{session}
        CMD
        project_root = tmux_options[/^default-path "(.+)"$/, 1]

        unless [s0, s1, s2].all?(&:success?)
          raise "Session '#{session}' doesn't exist."
        end

        panes = panes.each_line.map(&:split).group_by(&:first)
        windows = windows.each_line.map do |line|
          window_name, layout, active, path = line.split(" ")
          project_root ||= path if active.to_i == 1
          [
            window_name,
            layout,
            Array(panes[window_name]).map do |_, pane_path|
              "cd #{pane_path}"
            end
          ]
        end

        yaml = {
          "name" => name,
          "project_root" => project_root,
          "windows" => windows.map do |window_name, layout, window_panes|
            {
              window_name => {
                "layout" => layout,
                "panes" => window_panes
              }
            }
          end
        }

        path = config_path(name, options[:local])
        File.open(path, "w") do |f|
          f.write(YAML.dump(yaml))
        end
      end

      def find_project_file(name, local = false)
        path = config_path(name, local)
        if File.exist?(path)
          path
        else
          generate_project_file(name, path)
        end
      end

      def config_path(name, local = false)
        if local
          Tmuxinator::Config::LOCAL_DEFAULTS[0]
        else
          Tmuxinator::Config.default_project(name)
        end
      end

      def generate_project_file(name, path)
        template = Tmuxinator::Config.default? ? :default : :sample
        content = File.read(Tmuxinator::Config.send(template.to_sym))
        erb = Erubis::Eruby.new(content).result(binding)
        File.open(path, "w") { |f| f.write(erb) }
        path
      end

      def create_project(project_options = {})
        # Strings provided to --attach are coerced into booleans by Thor.
        # "f" and "false" will result in `:attach` being `false` and any other
        # string or the empty flag will result in `:attach` being `true`.
        # If the flag is not present, `:attach` will be `nil`.
        attach = detach = false
        attach = true if project_options[:attach] == true
        detach = true if project_options[:attach] == false

        options = {
          args: project_options[:args],
          custom_name: project_options[:custom_name],
          force_attach: attach,
          force_detach: detach,
          name: project_options[:name],
          project_config: project_options[:project_config]
        }

        begin
          Tmuxinator::Config.validate(options)
        rescue => e
          exit! e.message
        end
      end

      def render_project(project)
        if project.deprecations.any?
          project.deprecations.each { |deprecation| say deprecation, :red }
          show_continuation_prompt
        end

        Kernel.exec(project.render)
      end

      def version_warning?(suppress_flag)
        !Tmuxinator::TmuxVersion.supported? && !suppress_flag
      end

      def show_version_warning
        say Tmuxinator::TmuxVersion::UNSUPPORTED_VERSION_MSG, :red
        show_continuation_prompt
      end

      def show_continuation_prompt
        say
        print "Press ENTER to continue."
        STDIN.getc
      end

      def kill_project(project)
        Kernel.exec(project.kill)
      end
    end

    desc "start [PROJECT] [ARGS]", COMMANDS[:start]
    map "s" => :start
    method_option :attach, type: :boolean,
                           aliases: "-a",
                           desc: "Attach to tmux session after creation."
    method_option :name, aliases: "-n",
                         desc: "Give the session a different name"
    method_option "project-config", aliases: "-p",
                                    desc: "Path to project config file"
    method_option "suppress-tmux-version-warning",
                  desc: "Don't show a warning for unsupported tmux versions"

    def start(name = nil, *args)
      # project-config takes precedence over a named project in the case that
      # both are provided.
      if options["project-config"]
        args.unshift name if name
        name = nil
      end

      params = {
        args: args,
        attach: options[:attach],
        custom_name: options[:name],
        name: name,
        project_config: options["project-config"]
      }

      show_version_warning if version_warning?(
        options["suppress-tmux-version-warning"]
      )

      project = create_project(params)
      render_project(project)
    end

    desc "stop [PROJECT] [ARGS]", COMMANDS[:stop]
    map "st" => :stop
    method_option "project-config", aliases: "-p",
                                    desc: "Path to project config file"
    method_option "suppress-tmux-version-warning",
                  desc: "Don't show a warning for unsupported tmux versions"

    def stop(name = nil)
      # project-config takes precedence over a named project in the case that
      # both are provided.
      if options["project-config"]
        name = nil
      end

      params = {
        name: name,
        project_config: options["project-config"]
      }
      show_version_warning if version_warning?(
        options["suppress-tmux-version-warning"]
      )

      project = create_project(params)
      kill_project(project)
    end

    desc "local", COMMANDS[:local]
    map "." => :local
    method_option "suppress-tmux-version-warning",
                  desc: "Don't show a warning for unsupported tmux versions"

    def local
      show_version_warning if version_warning?(
        options["suppress-tmux-version-warning"]
      )

      render_project(create_project(attach: options[:attach]))
    end

    desc "debug [PROJECT] [ARGS]", COMMANDS[:debug]
    method_option :attach, type: :boolean,
                           aliases: "-a",
                           desc: "Attach to tmux session after creation."
    method_option :name, aliases: "-n",
                         desc: "Give the session a different name"
    method_option "project-config", aliases: "-p",
                                    desc: "Path to project config file"

    def debug(name = nil, *args)
      # project-config takes precedence over a named project in the case that
      # both are provided.
      if options["project-config"]
        args.unshift name if name
        name = nil
      end

      params = {
        args: args,
        attach: options[:attach],
        custom_name: options[:name],
        name: name,
        project_config: options["project-config"]
      }

      project = create_project(params)
      say project.render
    end

    desc "copy [EXISTING] [NEW]", COMMANDS[:copy]
    map "c" => :copy
    map "cp" => :copy

    def copy(existing, new)
      existing_config_path = Tmuxinator::Config.project(existing)
      new_config_path = Tmuxinator::Config.project(new)

      exit!("Project #{existing} doesn't exist!") \
        unless Tmuxinator::Config.exist?(name: existing)

      new_exists = Tmuxinator::Config.exist?(name: new)
      question = "#{new} already exists, would you like to overwrite it?"
      if !new_exists || yes?(question, :red)
        say "Overwriting #{new}" if Tmuxinator::Config.exist?(name: new)
        FileUtils.copy_file(existing_config_path, new_config_path)
      end

      Kernel.system("$EDITOR #{new_config_path}")
    end

    desc "delete [PROJECT1] [PROJECT2] ...", COMMANDS[:delete]
    map "d" => :delete
    map "rm" => :delete

    def delete(*projects)
      projects.each do |project|
        if Tmuxinator::Config.exist?(name: project)
          config = Tmuxinator::Config.project(project)

          if yes?("Are you sure you want to delete #{project}?(y/n)", :red)
            FileUtils.rm(config)
            say "Deleted #{project}"
          end
        else
          say "#{project} does not exist!"
        end
      end
    end

    desc "implode", COMMANDS[:implode]
    map "i" => :implode

    def implode
      if yes?("Are you sure you want to delete all tmuxinator configs?", :red)
        Tmuxinator::Config.directories.each do |directory|
          FileUtils.remove_dir(directory)
        end
        say "Deleted all tmuxinator projects."
      end
    end

    desc "list", COMMANDS[:list]
    map "l" => :list
    map "ls" => :list
    method_option :newline, type: :boolean,
                            aliases: ["-n"],
                            desc: "Force output to be one entry per line."

    def list
      say "tmuxinator projects:"
      if options[:newline]
        say Tmuxinator::Config.configs.join("\n")
      else
        print_in_columns Tmuxinator::Config.configs
      end
    end

    desc "version", COMMANDS[:version]
    map "-v" => :version

    def version
      say "tmuxinator #{Tmuxinator::VERSION}"
    end

    desc "doctor", COMMANDS[:doctor]

    def doctor
      say "Checking if tmux is installed ==> "
      yes_no Tmuxinator::Doctor.installed?

      say "Checking if $EDITOR is set ==> "
      yes_no Tmuxinator::Doctor.editor?

      say "Checking if $SHELL is set ==> "
      yes_no Tmuxinator::Doctor.shell?
    end

    # This method was defined as something of a workaround...  Previously
    # the conditional contained within was in the executable (i.e.
    # bin/tmuxinator).  It has been moved here so as to be testable. A couple
    # of notes:
    # - ::start (defined in Thor::Base) expects the first argument to be an
    # array or ARGV, not a varargs.  Perhaps ::bootstrap should as well?
    # - ::start has a different purpose from #start and hence a different
    # signature
    def self.bootstrap(args = [])
      name = args[0] || nil
      if args.empty? && Tmuxinator::Config.local?
        Tmuxinator::Cli.new.local
      elsif name && !Tmuxinator::Cli::RESERVED_COMMANDS.include?(name) &&
            Tmuxinator::Config.exist?(name: name)
        Tmuxinator::Cli.new.start(name, *args.drop(1))
      else
        Tmuxinator::Cli.start(args)
      end
    end
  end
end
