require "spec_helper"
require "integration_helper"
require "childprocess"

describe "tmux integration test", integration: true do
  def wait_for_session(session_name)
    Timeout::timeout(15) do
      loop do
        break if tmux_list_sessions.include?(session_name)
      end
    end
    # Session may have started, but commands and shells may not be up yet
    sleep(2)
  end

  describe "simple project" do
    before(:all) do
      fixture = fixture_path("integration/simple.yml")
      @project = Tmuxinator::Project.load(fixture)

      @script = Tempfile.new(@project.name)
      @script.write(@project.render)
      @script.rewind

      @tmux = ChildProcess.new("sh", @script.path)
      @tmux.start

      wait_for_session(@project.name)
    end

    after(:all) do
      `#{@project.tmux_kill_session_command}`
      @script.close
      @tmux.stop
    end

    it "starts the session with the correct name" do
      sessions = tmux_list_sessions
      expect(sessions).to include(@project.name)
    end

    it "has the correct windows" do
      windows = tmux_list_windows(@project.name)
      expect(windows).to include("one", "two", "three")
    end

    it "correctly executes commands" do
      %w(one two three).each do |window|
        `tmux capture-pane -t #{@project.name}:#{window} -b test`
        output = `tmux show-buffer -b test`.strip!
        expect(output).to include("echo \"#{window}\"")
      end
    end
  end
end