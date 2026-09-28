import { Controller } from "@hotwired/stimulus"

// Bulk actions in maintenance mode: only deleting asks first.
export default class extends Controller {
  confirm(event) {
    const op = this.element.querySelector("[name=bulk_op]").value
    const count = document.querySelectorAll("input.select-card:checked").length
    if (op === "delete" && !window.confirm(`Delete ${count} card${count === 1 ? "" : "s"}?`)) {
      event.preventDefault()
    }
  }
}
