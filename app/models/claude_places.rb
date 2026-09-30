# Where Bobby can start Claude from onbox: a chat (one scratch folder, each
# chat its own session), or any git project one level under the folders in
# STACK_PROJECT_DIRS (colon-separated, default ~/code), most recently touched
# first. Only these places can be picked, never a typed path.
module ClaudePlaces
  CHAT = "chat".freeze

  module_function

  def roots
    ENV.fetch("STACK_PROJECT_DIRS", "~/code").split(":").map { |dir| File.expand_path(dir) }
  rescue ArgumentError # no HOME
    []
  end

  def projects
    roots.flat_map { |root| Dir.glob(File.join(root, "*", ".git")).map { |git| File.dirname(git) } }
      .uniq.sort_by { |dir| -File.mtime(dir).to_f }
  end

  # [label, value] pairs for a select.
  def options
    [ [ "Chat", CHAT ] ] + projects.map { |dir| [ File.basename(dir), dir ] }
  end

  # The folder for a picked value, or nil when it isn't one of the places.
  def resolve(value)
    return ClaudeRun.chat_dir if value.blank? || value == CHAT
    projects.find { |dir| dir == value }
  end
end
