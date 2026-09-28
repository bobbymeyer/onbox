namespace :gmail do
  desc "Connect an email source to Gmail (run on the Mac, with a browser): bin/rails gmail:connect[gmail]"
  task :connect, [ :source ] => :environment do |_, args|
    abort "Set GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET first (see README)." unless Gmail::Authorization.configured?

    name = args[:source].presence || "gmail"
    source = Source.find_or_create_by!(name: name) { |s| s.kind = "email" }
    abort "#{name} is a #{source.kind} source, not email." unless source.email?

    puts "1. Open this URL and approve access:\n\n#{Gmail::Authorization.url}\n\n"
    puts "2. The browser lands on a localhost page that fails to load. Paste its full URL here:"
    print "> "
    source.update!(secret: Gmail::Authorization.exchange($stdin.gets))
    puts "Connected #{name} as #{Gmail::Mailbox.new(source).address}. Query: #{source.email_query}"
  end

  desc "Poll connected email sources once"
  task poll: :environment do
    Source.email.select(&:connected?).each do |source|
      cards = Gmail::Sync.call(source)
      puts "#{source.name}: #{cards.size} new card(s)"
    end
  end
end
