import { Controller } from "@hotwired/stimulus"

// Flipping to the back is logged (flip rate is an intake health metric) and
// unlocks the stamps that are too irreversible to send from the front.
export default class extends Controller {
  static targets = ["gated"]
  static values = { url: String }

  flipped(event) {
    if (!event.target.open || this.logged) return
    this.logged = true
    this.gatedTargets.forEach((button) => (button.disabled = false))

    const token = document.querySelector("meta[name=csrf-token]")?.content
    fetch(this.urlValue, { method: "POST", headers: { "X-CSRF-Token": token } })
  }
}
