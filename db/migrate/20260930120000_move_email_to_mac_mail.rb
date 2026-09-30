# Email moves from the Gmail API to the Mac's Mail: the Gmail refresh token,
# the Google OAuth client and the Gmail search go; a source still named
# "gmail" becomes "mail", since it now reads every account in Mail.
class MoveEmailToMacMail < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM credentials WHERE name IN ('google_client_id', 'google_client_secret')"
    execute "UPDATE sources SET settings = json_remove(settings, '$.query', '$.last_polled_at', '$.last_error') WHERE kind = 'email'"
    unless select_value("SELECT 1 FROM sources WHERE name = 'mail'")
      execute "UPDATE sources SET name = 'mail' WHERE name = 'gmail' AND kind = 'email'"
    end
    remove_column :sources, :secret
  end

  def down
    add_column :sources, :secret, :text
  end
end
