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

Stamp.find_or_create_by!(label: "Done", card_type: "any") do |s|
  s.action = { "kind" => "handle" }
end

puts "claude-code source token: #{claude.token}"
