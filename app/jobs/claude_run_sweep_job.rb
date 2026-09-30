# Finishes Claude runs that exited while onbox wasn't watching (a restart).
class ClaudeRunSweepJob < ApplicationJob
  queue_as :default

  def perform
    ClaudeRun.sweep!
  end
end
