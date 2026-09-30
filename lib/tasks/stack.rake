namespace :stack do
  desc "Write any secretary digests whose window has closed"
  task digest: :environment do
    written = Accountant.run
    puts written.any? ? written.map { |a| "#{a.title}\n#{a.body}\n" } : "Nothing new to account for"
  end
end
