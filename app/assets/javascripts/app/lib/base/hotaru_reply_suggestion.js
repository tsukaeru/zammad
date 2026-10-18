/* Copyright (C) 2026 Tsukaeru. Customer reply previews never enter the editor until accepted. */
(function (global) {
  'use strict'
  class HotaruReplySuggestion {
    constructor(options) {
      Object.assign(this, options)
      this.generation = 0
      this.attempted = false
      this.listeners = []
      this.panel = document.createElement('div')
      this.panel.className = 'hotaru-reply-suggestion'
      this.panel.innerHTML = '<div class="hotaru-reply-preview" hidden></div><div class="hotaru-reply-status" role="status" aria-live="polite"></div><button type="button" class="hotaru-reply-accept" hidden>Accept reply suggestion (Tab)</button><button type="button" class="hotaru-reply-retry" hidden>Retry reply suggestion</button>'
      this.editor.before(this.panel)
      this.preview = this.panel.querySelector('.hotaru-reply-preview')
      this.status = this.panel.querySelector('.hotaru-reply-status')
      this.acceptButton = this.panel.querySelector('.hotaru-reply-accept')
      this.retryButton = this.panel.querySelector('.hotaru-reply-retry')
      this.listen(this.editor, 'focus', () => { if (!this.attempted) this.generate() })
      this.listen(this.editor, 'keydown', (event) => this.keydown(event))
      this.listen(this.root, 'input', () => this.invalidate())
      this.listen(this.root, 'change', () => this.invalidate())
      this.listen(this.acceptButton, 'click', () => this.accept())
      this.listen(this.retryButton, 'click', () => this.retry())
      this.listen(document, 'focusin', (event) => {
        if (![this.editor, this.acceptButton, this.retryButton].includes(event.target)) this.invalidate()
      })
      this.listen(global, 'hashchange', () => this.invalidate())
      this.observer = new MutationObserver(() => {
        if (this.baseline !== undefined && this.editor.innerHTML !== this.baseline) this.invalidate()
      })
      this.observer.observe(this.editor, { childList: true, subtree: true, characterData: true, attributes: true })
    }
    listen(element, event, callback) {
      element.addEventListener(event, callback)
      this.listeners.push(() => element.removeEventListener(event, callback))
    }
    empty() {
      const copy = this.editor.cloneNode(true)
      copy.querySelectorAll('[data-signature="true"], blockquote').forEach((node) => node.remove())
      return !copy.textContent.replace(/\u00a0/g, ' ').trim() && !copy.querySelector('img, table, hr, video, audio, iframe')
    }
    current(generation, focus = false) {
      return generation === this.generation && this.editor.isConnected && this.eligible() &&
        this.empty() && this.editor.innerHTML === this.baseline && this.context() === this.snapshot &&
        (!focus || [this.editor, this.acceptButton].includes(document.activeElement))
    }
    invalidate() {
      this.generation += 1
      this.abort?.abort()
      this.suggestion = null
      this.accepting = false
      this.preview.hidden = true
      this.acceptButton.hidden = true
      this.status.textContent = ''
      this.retryButton.hidden = !this.eligible() || !this.empty()
    }
    retry() {
      this.invalidate()
      this.editor.focus()
      return this.generate()
    }
    async call(action, data) {
      const controller = new AbortController()
      this.abort = controller
      let timer
      try {
        return await Promise.race([
          this.request(action, data, controller.signal),
          new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reject(new Error('timeout')) }, this.timeout || 55000) }),
        ])
      } finally { clearTimeout(timer) }
    }
    async generate() {
      if (!this.eligible() || !this.empty()) return
      this.attempted = true
      this.invalidate()
      const generation = this.generation
      this.baseline = this.editor.innerHTML
      this.snapshot = this.context()
      this.retryButton.hidden = true
      this.status.textContent = 'Preparing reply suggestion…'
      const request_id = global.crypto.randomUUID()
      try {
        const result = await this.call('generate', { request_id, language: 'auto' })
        if (!this.current(generation)) return
        if (result.request_id !== request_id || !['ready', 'none'].includes(result.status)) throw new Error('invalid response')
        this.status.textContent = ''
        if (result.status === 'none') return
        if (typeof result.draft !== 'string' || !result.draft.trim() || result.draft.length > 12000 || !/^[a-f0-9]{64}$/.test(result.evidence_revision)) throw new Error('invalid response')
        this.suggestion = result
        this.preview.textContent = result.draft
        this.preview.hidden = false
        this.acceptButton.hidden = false
      } catch (_) {
        if (generation !== this.generation) return
        this.status.textContent = 'Reply suggestion unavailable. You can continue composing or retry.'
        this.retryButton.hidden = false
      }
    }
    competingMenu() {
      const module = global.jQuery?.data(this.editor, 'plugin_textmodule')
      if (module?.isActive()) return true
      return Array.from(this.root.querySelectorAll('.text-modules-box, [role="listbox"], .ui-autocomplete')).some((node) => node.getClientRects().length > 0)
    }
    keydown(event) {
      if (event.key === 'Escape') { this.invalidate(); return }
      if (event.key !== 'Tab' || event.shiftKey || event.altKey || event.ctrlKey || event.metaKey || event.isComposing || this.competingMenu()) return
      if ((!this.suggestion && !this.accepting) || !this.current(this.generation, true)) return
      event.preventDefault()
      event.stopImmediatePropagation()
      if (!this.accepting) this.accept()
    }
    async accept() {
      if (!this.suggestion || this.accepting || this.competingMenu()) return
      const generation = this.generation
      if (!this.current(generation, true)) { this.invalidate(); return }
      const suggestion = this.suggestion
      this.accepting = true
      this.status.textContent = 'Checking reply suggestion…'
      try {
        const result = await this.call('validate', { request_id: suggestion.request_id, language: 'auto', evidence_revision: suggestion.evidence_revision })
        if (!this.current(generation, true)) { this.invalidate(); return }
        if (result.request_id !== suggestion.request_id || result.valid !== true) { this.invalidate(); return }
        this.invalidate()
        this.editor.focus()
        const range = document.createRange()
        range.selectNodeContents(this.editor)
        range.collapse(true)
        const selection = global.getSelection()
        selection.removeAllRanges()
        selection.addRange(range)
        const escaped = document.createElement('div')
        escaped.textContent = suggestion.draft
        this.insert(escaped.innerHTML.replace(/\r?\n/g, '<br>') + '<br><br>')
        this.editor.dispatchEvent(new Event('input', { bubbles: true }))
        this.editor.dispatchEvent(new Event('change', { bubbles: true }))
      } catch (_) {
        if (generation !== this.generation) return
        this.invalidate()
        this.status.textContent = 'Reply suggestion could not be checked. Retry to generate a fresh suggestion.'
      }
    }
    destroy() {
      this.invalidate()
      this.observer.disconnect()
      this.listeners.forEach((remove) => remove())
      this.panel.remove()
    }
  }
  global.HotaruReplySuggestion = HotaruReplySuggestion
})(window)
