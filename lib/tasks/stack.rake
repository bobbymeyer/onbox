namespace :stack do
  desc "Write any secretary digests whose window has closed"
  task digest: :environment do
    written = Accountant.run
    puts written.any? ? written.map { |a| "#{a.title}\n#{a.body}\n" } : "Nothing new to account for"
  end
end

namespace :stack do
  desc "Connect this Mac's Claude Code and Claude desktop app to the stack (hooks, stack tools, standing instruction)"
  task connect: :environment do
    puts ClaudeSetup.connect!
  end
end
