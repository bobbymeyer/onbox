# The first source and the first stamps. Idempotent.

claude = Source.find_or_create_by!(name: "claude-code") { |s| s.kind = "claude_code" }

Stamp.find_or_create_by!(label: "Approve", card_type: "any") do |s|
  s.action = { "kind" => "instruct" }
  s.template = nil # sends the card's proposed action as drafted
end

Stamp.find_or_create_by!(label: "PR and merge", card_type: "agent") do |s|
  s.action = { "kind" => "instruct" }
  s.template = "Open a PR for this work and merge it once CI is green. Report back with the PR link."
  s.successors = [
    { "summary" => "Deploy {{project}}", "ask" => "acknowledge" },
    { "summary" => "Tell whoever is waiting that {{project}} shipped", "ask" => "reply" }
  ]
end

Stamp.find_or_create_by!(label: "Keep going", card_type: "agent") do |s|
  s.action = { "kind" => "instruct" }
  s.template = "Looks right. Keep going."
end

Source.find_or_create_by!(name: "mail") { |s| s.kind = "email" }

Stamp.find_or_create_by!(label: "Archive", card_type: "email") do |s|
  s.action = { "kind" => "archive" }
end

Source.find_or_create_by!(name: "calendar") { |s| s.kind = "calendar" }
Source.find_or_create_by!(name: "reminders") { |s| s.kind = "reminders" }

Stamp.find_or_create_by!(label: "Allow", card_type: "permission") do |s|
  s.action = { "kind" => "allow" }
end

Stamp.find_or_create_by!(label: "Done", card_type: "any") do |s|
  s.action = { "kind" => "handle" }
end

puts "claude-code source token: #{claude.token}"
