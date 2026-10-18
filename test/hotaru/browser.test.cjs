const { test, before, after } = require('node:test')
const assert = require('node:assert/strict')
const { chromium } = require('playwright')
const path = require('node:path')
const fs = require('node:fs')
const coffee = require('coffee-script')
let browser
const asset = (name) => path.resolve(__dirname, '../../app/assets/javascripts/app', name)
before(async () => { browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true }) })
after(async () => { await browser?.close() })
async function fixture(t, body = '') {
  const page = await browser.newPage()
  t.after(() => page.close())
  await page.route('http://localhost/', (route) => route.fulfill({ contentType: 'text/html', body: `<form id="composer"><div id="editor" contenteditable="true" data-name="body">${body}</div><input name="to" value="customer@example.test"><button type="submit">Send</button></form><button id="outside">Outside</button>` }))
  await page.goto('http://localhost/')
  await page.addStyleTag({ path: path.resolve(__dirname, '../../app/assets/stylesheets/custom/hotaru_reply_suggestion.css') })
  await page.addScriptTag({ path: asset('lib/core/jquery-3.6.0.js') })
  await page.evaluate(() => { window.App = { Browser: { magicKey: () => 'metaKey', hotkeys: () => ({}) } }; $.fn.enableObjectResizingShim = function () { return this }; $('#composer').on('submit', (e) => { e.preventDefault(); window.posts = (window.posts || 0) + 1 }) })
  await page.addScriptTag({ path: asset('lib/base/jquery.contenteditable.js') })
  await page.addScriptTag({ path: asset('lib/base/hotaru_reply_suggestion.js') })
  await page.evaluate(() => {
    window.App.Controller = function () {}; App.Controller.include = function () {}
  })
  await page.addScriptTag({ content: coffee.compile(fs.readFileSync(asset('controllers/ticket_zoom/article_new.coffee'), 'utf8')) })
  await page.evaluate(() => {
    $('#editor').ce({ mode: 'richtext', multiline: true })
    window.calls = []; window.allowed = true; window.revision = 'a'.repeat(64); window.pending = null
    const config = { api_path: '/api/v1', hotaru_reply_drafts: true, hotaru_reply_draft_group_ids: [5] }
    App.Config = { get: (key) => config[key] }; App.Ajax = { token: () => 'synthetic-csrf' }
    document.querySelector('form').className = 'is-public'
    document.body.className = 'content active'
    window.fetch = async (url, options) => {
        const action = url.endsWith('/validate') ? 'validate' : 'generate'
        const data = JSON.parse(options.body)
        calls.push({ action, data })
        if (pending) await pending
        return { ok: true, json: async () => action === 'validate' ? { valid: true, request_id: data.request_id } : { status: 'ready', draft: 'Hello <customer>\n\nPlease try again.', language: 'en', request_id: data.request_id, evidence_revision: revision } }
    }
    const controller = {
      ticket: { id: 17, group_id: 5, updated_at: 'one', currentView: () => allowed ? 'agent' : 'customer', subscribe: (callback) => { window.ticketChanged = callback; return 1 } },
      ticket_id: 17, type: 'email', textarea: $('#editor'), articleNewEdit: $('#composer')
    }
    App.TicketZoomArticleNew.prototype.initHotaruReplySuggestion.call(controller)
    window.widget = controller.hotaruReplySuggestion
    window.composer = controller
    window.config = config
  })
  return page
}
async function ready(page) { await page.locator('#editor').focus(); await page.waitForSelector('.hotaru-reply-preview:not([hidden])') }
test('test_tab_accepts_preview_as_editable_text_without_posting', async (t) => {
  const page = await fixture(t)
  await ready(page)
  if (process.env.PREVIEW_SCREENSHOT) await page.screenshot({ path: process.env.PREVIEW_SCREENSHOT })
  await page.keyboard.press('Tab')
  await page.waitForFunction(() => document.querySelector('#editor').textContent.includes('Hello <customer>'))
  assert.equal(await page.evaluate(() => window.posts || 0), 0)
  assert.equal(await page.locator('#editor customer').count(), 0)
  assert.equal(await page.evaluate(() => calls.filter((c) => c.action === 'validate').length), 1)
  await page.keyboard.press('ControlOrMeta+z')
  assert.equal(await page.locator('#editor').textContent(), '')
})
test('test_preview_is_excluded_from_submit_autosave_and_shared_drafts', async (t) => {
  const page = await fixture(t)
  await ready(page)
  assert.equal(await page.locator('#editor').innerHTML(), '')
  assert.equal(await page.evaluate(() => $('#editor').ceg()), '')
  assert.equal(await page.locator('#editor .hotaru-reply-preview').count(), 0)
  assert.equal(await page.evaluate(() => new FormData(document.querySelector('form')).has('draft')), false)
})
test('test_existing_draft_signature_and_autocomplete_are_preserved', async (t) => {
  const page = await fixture(t, '<div data-signature="true">Regards Agent</div><blockquote>Original question</blockquote>')
  await ready(page)
  await page.evaluate(() => { $.data(document.querySelector('#editor'), 'plugin_textmodule', { isActive: () => true }) })
  assert.equal(await page.evaluate(() => document.querySelector('#editor').dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true }))), true)
  assert.equal(await page.evaluate(() => calls.filter((c) => c.action === 'validate').length), 0)
  await page.evaluate(() => { $.removeData(document.querySelector('#editor'), 'plugin_textmodule') })
  await page.locator('#editor').focus()
  assert.equal(await page.evaluate(() => document.querySelector('#editor').dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true, cancelable: true }))), true)
  assert.equal(await page.evaluate(() => calls.filter((c) => c.action === 'validate').length), 0)
  await page.locator('.hotaru-reply-accept').click()
  await page.waitForFunction(() => document.querySelector('#editor').textContent.includes('Hello'))
  assert.equal(await page.locator('[data-signature]').textContent(), 'Regards Agent')
  assert.equal(await page.locator('blockquote').textContent(), 'Original question')
  const draft = await fixture(t, '<p>Existing authored reply</p>')
  await draft.locator('#editor').focus()
  assert.equal(await draft.evaluate(() => calls.length), 0)
})
test('test_typing_escape_navigation_and_late_results_dismiss_preview', async (t) => {
  const page = await fixture(t)
  await ready(page)
  await page.keyboard.press('Escape')
  assert.equal(await page.locator('.hotaru-reply-preview').isVisible(), false)
  await page.evaluate(() => widget.retry())
  await ready(page)
  await page.keyboard.type('My own reply')
  assert.equal(await page.locator('.hotaru-reply-preview').isVisible(), false)
  await page.evaluate(() => { document.querySelector('#editor').innerHTML = ''; window.pending = new Promise((resolve) => { window.resolvePending = resolve }); widget.retry() })
  await page.evaluate(() => { widget.invalidate(); resolvePending() })
  await page.waitForTimeout(20)
  assert.equal(await page.locator('.hotaru-reply-preview').isVisible(), false)
})
test('test_changed_ticket_revision_or_access_discards_result', async (t) => {
  const page = await fixture(t)
  await ready(page)
  await page.evaluate(() => { window.pending = new Promise((resolve) => { window.resolvePending = resolve }) })
  await page.keyboard.press('Tab')
  await page.keyboard.press('Tab')
  await page.evaluate(() => { allowed = false; resolvePending() })
  await page.waitForTimeout(20)
  assert.equal(await page.locator('#editor').textContent(), '')
  assert.equal(await page.evaluate(() => calls.filter((c) => c.action === 'validate').length), 1)
})
test('test_timeout_rate_limit_and_duplicate_requests_never_post', async (t) => {
  const page = await fixture(t)
  await page.evaluate(() => { widget.timeout = 20; window.pending = new Promise(() => {}) })
  await page.locator('#editor').focus()
  await page.waitForFunction(() => document.querySelector('.hotaru-reply-status').textContent.includes('unavailable'))
  assert.equal(await page.evaluate(() => calls.length), 1)
  assert.equal(await page.evaluate(() => window.posts || 0), 0)
  await page.evaluate(() => { pending = null })
  await page.locator('.hotaru-reply-retry').click()
  await page.waitForSelector('.hotaru-reply-preview:not([hidden])')
  assert.equal(await page.evaluate(() => calls.length), 2)
})
test('new articles, recipient changes and navigation discard previews', async (t) => {
  const page = await fixture(t)
  await ready(page)
  await page.evaluate(() => ticketChanged())
  assert.equal(await page.locator('.hotaru-reply-preview').isVisible(), false)
  await page.evaluate(() => widget.retry())
  await ready(page)
  await page.locator('[name=to]').fill('other@example.test')
  assert.equal(await page.locator('.hotaru-reply-preview').isVisible(), false)
  await page.evaluate(() => widget.retry())
  await ready(page)
  await page.evaluate(() => { location.hash = '#ticket/99' })
  await page.waitForFunction(() => document.querySelector('.hotaru-reply-preview').hidden)
})
test('typing while acceptance validation is pending preserves the authored draft', async (t) => {
  const page = await fixture(t)
  await ready(page)
  await page.evaluate(() => { window.pending = new Promise((resolve) => { window.resolvePending = resolve }) })
  await page.keyboard.press('Tab')
  await page.keyboard.type('An agent reply')
  await page.evaluate(() => resolvePending())
  await page.waitForTimeout(20)
  assert.equal(await page.locator('#editor').textContent(), 'An agent reply')
})
test('feature disable and group removal stop generation and acceptance', async (t) => {
  const page = await fixture(t)
  await page.evaluate(() => { config.hotaru_reply_drafts = false })
  await page.locator('#editor').focus()
  assert.equal(await page.evaluate(() => calls.length), 0)
  await page.evaluate(() => { config.hotaru_reply_drafts = true; widget.retry() })
  await ready(page)
  await page.evaluate(() => { config.hotaru_reply_draft_group_ids = [] })
  await page.keyboard.press('Tab')
  assert.equal(await page.locator('#editor').textContent(), '')
  assert.equal(await page.evaluate(() => calls.length), 1)
})

test('the production text module menu has Tab priority', async (t) => {
  const page = await fixture(t)
  await ready(page)
  await page.addScriptTag({ path: asset('lib/core/underscore-1.8.3.js') })
  await page.addScriptTag({ path: asset('lib/base/jquery.textmodule.js') })
  await page.evaluate(() => {
    $('#editor').textmodule()
    const module = $.data(document.querySelector('#editor'), 'plugin_textmodule')
    module.active = true
  })
  assert.equal(await page.evaluate(() => document.querySelector('#editor').dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', keyCode: 9, bubbles: true, cancelable: true }))), true)
  assert.equal(await page.evaluate(() => calls.filter((c) => c.action === 'validate').length), 0)
})
