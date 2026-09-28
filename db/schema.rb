# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_28_203638) do
  create_table "cards", force: :cascade do |t|
    t.integer "source_id"
    t.string "key"
    t.string "card_type", default: "generic", null: false
    t.string "project"
    t.string "summary"
    t.string "ask", default: "acknowledge", null: false
    t.text "proposed_action"
    t.json "payload", default: {}, null: false
    t.string "state", default: "live", null: false
    t.integer "position", default: 0, null: false
    t.datetime "hold_until"
    t.string "hold_event"
    t.integer "parent_card_id"
    t.integer "blocked_by_id"
    t.datetime "handled_at"
    t.string "handled_with"
    t.datetime "digested_at"
    t.integer "flip_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blocked_by_id"], name: "index_cards_on_blocked_by_id"
    t.index ["key"], name: "index_cards_on_key"
    t.index ["parent_card_id"], name: "index_cards_on_parent_card_id"
    t.index ["source_id"], name: "index_cards_on_source_id"
    t.index ["state", "position"], name: "index_cards_on_state_and_position"
  end

  create_table "handlings", force: :cascade do |t|
    t.integer "card_id", null: false
    t.integer "stamp_id"
    t.string "verb", null: false
    t.text "text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["card_id"], name: "index_handlings_on_card_id"
    t.index ["stamp_id"], name: "index_handlings_on_stamp_id"
    t.index ["verb"], name: "index_handlings_on_verb"
  end

  create_table "sources", force: :cascade do |t|
    t.string "name", null: false
    t.string "kind", default: "generic", null: false
    t.string "token", null: false
    t.string "card_type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_sources_on_name", unique: true
    t.index ["token"], name: "index_sources_on_token", unique: true
  end

  create_table "stamps", force: :cascade do |t|
    t.string "label", null: false
    t.string "card_type", default: "any", null: false
    t.json "action", default: {}, null: false
    t.text "template"
    t.json "successors", default: [], null: false
    t.integer "use_count", default: 0, null: false
    t.boolean "requires_flip", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["card_type"], name: "index_stamps_on_card_type"
  end

  create_table "triggers", force: :cascade do |t|
    t.integer "card_id", null: false
    t.string "kind", default: "time", null: false
    t.datetime "fires_at"
    t.string "event_key"
    t.datetime "fired_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["card_id"], name: "index_triggers_on_card_id"
    t.index ["event_key"], name: "index_triggers_on_event_key"
    t.index ["kind", "fired_at", "fires_at"], name: "index_triggers_on_kind_and_fired_at_and_fires_at"
  end

  add_foreign_key "cards", "cards", column: "blocked_by_id"
  add_foreign_key "cards", "cards", column: "parent_card_id"
  add_foreign_key "cards", "sources"
  add_foreign_key "handlings", "cards"
  add_foreign_key "handlings", "stamps"
  add_foreign_key "triggers", "cards"
end
