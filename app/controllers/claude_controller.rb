# Starting Claude from onbox: a chat or a session in a project, run on the Mac
# on Bobby's Max plan. Its reply lands in the stack as a card; replying on the
# card continues the session.
class ClaudeController < ApplicationController
  def show
    @places = ClaudePlaces.options
    @runs = ClaudeRun.recent.includes(:result_card).limit(20)
  end

  def create
    prompt = params[:prompt].to_s.strip
    cwd = ClaudePlaces.resolve(params[:place])
    return redirect_to(claude_path, alert: "Say what you want Claude to do.") if prompt.blank?
    return redirect_to(claude_path, alert: "That isn't one of your projects.") unless cwd
    return redirect_to(claude_path, alert: ClaudeCli.not_found_message) unless ClaudeCli.found?

    run = ClaudeRun.start!(prompt: prompt, cwd: cwd)
    if run.failed?
      redirect_to claude_path, alert: "Claude didn't start: #{run.error}"
    else
      redirect_to claude_path, notice: "Claude is on it in #{run.project}. The reply will land in the stack."
    end
  end

  def stop
    ClaudeRun.find(params[:id]).stop!
    redirect_to claude_path, notice: "Stopped."
  end
end
