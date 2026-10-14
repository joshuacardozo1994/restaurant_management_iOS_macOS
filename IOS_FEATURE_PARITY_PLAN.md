# iOS Feature Parity Plan

Bringing the Durigo iOS app to parity with the restaurant-management web app. iOS is the primary device used in the restaurant.

## Architectural decisions (revised)

### What we preserve from the existing iOS app
- **Bill Generator** — the unique iOS feature (custom items, inline name/price edit, table+waiter dropdown, PDF print). This is the only piece staff actively uses today and the only feature being kept verbatim.
- **Fonts and shared visual assets**.

### What we rewrite or replace
- Bill History (currently SwiftData-only) → server-driven with SwiftData cache
- Stats / Reports → mirror web's `/reports` endpoints
- Menu views → live from server
- Auth → JWT login matching the website
- Everything else.

### Network + auth model
- **Login is the gate.** Username + password (matching the existing web user accounts: admin/admin123, waiter/waiter123, etc.) → server returns JWT → iOS stores in Keychain.
- All API calls send the JWT as `Cookie: auth-token=<jwt>`. This is what the existing middleware (`proxy.ts`) reads; we don't need a separate auth path.
- The old bearer-token (`BILL_UPLOAD_API_TOKEN`) approach is **deprecated** for the iOS app. The endpoint stays for any future machine-to-machine integration but iOS will no longer use it.

### Storage model: SwiftData canonical + bidirectional sync
- **SwiftData = local canonical store.** Always read from SwiftData for display. Works offline by definition.
- **On app foreground (and pull-to-refresh)**:
  1. Pull from server → upsert into SwiftData (server is authoritative for already-uploaded bills)
  2. Push local-only bills (`syncedAt == nil`) → server → mark synced
- **Failures are silent** — UI keeps showing cached data; only show errors when user takes an explicit sync action.
- **Bills created offline** stay in SwiftData with `syncedAt = nil` and get uploaded next time online.

### Adaptive layout
- Every new screen uses `@Environment(\.horizontalSizeClass)` to adapt: compact (iPhone) → `NavigationStack`; regular (iPad) → `NavigationSplitView`. No platform-specific code paths.

## Parity audit against the web app (14 Oct 2026)

A feature-by-feature comparison with the web POS (see `docs/qa/functional-test-plan.md`
in restaurant-management). ✅ = done and verified (how, in brackets), ☑️ = done, builds and
unit-tested but not yet checked by hand on a device, ⬜ = still to do.

**Money and data correctness**
- ✅ Bill Generator receipts show GST on food (as CGST + SGST) and VAT on liquor, worked out the way the server records them (`BillMath` in `Menu/Models.swift`, a port of `bill-math.ts`). Rates come from server settings, cached for offline printing. Liquor is recognised by its menu category (`taxType` on `/api/menu/full`); custom items by whole-word name match. [unit tests with the server's own cases; receipt rendered by `testRenderReceiptForReview`]
- ✅ Liquor keywords match whole words only: "gin" no longer matches "Ginger"/"Virgin", "port" not "portion", "rum" not "drumsticks". Same fix on the server. [unit tests both sides]
- ✅ Line totals are rounded like the server's (half a ₹155 portion is ₹78, not ₹77). [unit test]
- ✅ POS table payment is one server call (`POST /api/orders/:id/payment` with `expectedTotal`): the server records the bill, completes the orders and frees the table in one transaction. Previously the app also PATCHed each order and PUT the table itself, swallowing "already exists" errors. [simulator: ₹580 paid by cash → server recorded GST ₹12, VAT ₹58; table freed]
- ✅ A bill that changed on another device is refused with the server's message and the screen reloads. [simulator: item added server-side, "The bill changed from ₹560 to ₹580…"]
- ✅ POS tables grid updates live. The SSE handler expected a `{type, data}` wrapper the server doesn't send, so it ignored every event; it now reloads the grid (debounced) on order/table/payment events and after reconnecting. [simulator: order placed from another client appeared without touching the phone]
- ✅ Server error messages are shown as written instead of "Server returned 409: {json}". [simulator]
- ✅ Settings: GST and liquor VAT as percentages, prices-include-tax switch, VAT TIN. The screen previously failed to load because the low-stock threshold (0.2) was decoded as an integer. [simulator: screen loads with the new fields]
- ☑️ POS orders send an idempotency key (reused on retry, renewed when the cart changes), so a retry after a dropped connection can't place the order twice.
- ☑️ CA report shows GST and VAT collected, in the tiles and the copy-for-CA text.
- ☑️ Reservations: table optional ("Assign later"); dates and times sent in IST.
- ☑️ The unit-test target now builds against the app (`@testable import Durigo`, iOS 18 deployment target). It had never compiled against it. One existing test, `testShouldFilterMenuWithQuery` (fuzzy menu search threshold), fails and needs a decision on the intended search behaviour.

**Second pass (14 Oct 2026)**: iPhone, iPad and Mac all build after every change
- ✅ The Mac app builds and runs again. The build had broken (iOS-only APIs, an Info.plist key macOS rejects), and the sandboxed Mac app had no network, print or microphone entitlement, so it couldn't even sign in. [Mac: signed in, tables grid and payment sheet]
- ✅ Role-based screens: each role sees what the web gives it (waiters also keep Billing, the Bill Generator history); restaurant settings admin-only. [simulator: kitchen, waiter, cashier]
- ✅ Per-item kitchen notes; delivery customer/phone/address go in the order note (the server has no customer fields, so they were dropped); kitchen cards show order and item notes in red. [simulator]
- ✅ POS payment: GST/VAT breakdown, discount code or ₹ discount (cashier/admin), split bill, receipt after paying (print/share PDF). [UI test POSPaymentUITests + server record: QA10, ₹513 cash + ₹513 UPI]
- ✅ Manage tables: add, renumber, seats, out of service and back, delete (admin). [UI test ManageTablesUITests]
- ✅ Kitchen chime and kitchen-ticket printing (auto or per card; iPhone/iPad to a chosen printer, Mac to the default printer). [ticket rendered in a unit test; new-order trigger verified on the simulator] ⚠️ Not yet tried on the real kitchen printer or speaker.

**Still to do**
- ⬜ Receipt identity (name, GSTIN, VAT TIN, address, phone) from settings instead of hard-coded, once production settings hold Durigo's details.
- ⬜ List each tender ("Paid by: ₹513 cash, ₹513 UPI") on the iOS receipt, as the web receipt does.
- ⬜ `testShouldFilterMenuWithQuery` fails: decide how forgiving menu search should be.
- ⬜ `AdminScreensUITests` still launch with the old `--autologin` arguments and admin/admin123; move them to `--auto-signin` with the QA password from TEST_RUNNER_QA_PASS.

## Phase order (revised)

| # | Phase | Estimate | Status |
|---|---|---|---|
| 0 | **Auth foundation**: REST login endpoint, iOS Login screen, JWT cookie wiring | ~2h | done |
| 1 | **Bill upload** (Bill Generator → server) + **Bill history sync** (server → SwiftData) | ~3h | done |
| 2 | **Menu management** (CRUD via authenticated endpoints) | 1-2 days | done |
| 3 | **Settings + Users** sync | 1 day | done |
| 4 | **Live ops**: POS tables, Kitchen, SSE | ~1 week | partial — Kitchen + SSE done; iOS POS = BillGenerator by design (no table-grid) |
| 5 | **Reports parity** (sales, customers, staff, inventory) | 2-3 days | done |
| 6 | **Long tail**: Discounts, inventory, reservations, modifiers | ~1 week | done |

### Known deferred items
- **Bill→waiter ID resolution.** iOS uploads `waiterName` (string), server matches by case-insensitive `User.name`. Mismatch → `waiterId` null → Staff report shows ₹0 from iOS-origin orders. Fix path: have iOS post `waiterId` from logged-in `Session.user.id`.
- **Bill→customer linking.** `Order.customerId` is never set on iOS uploads. Customers report is structurally empty for iOS bills. Fix path: add a customer-tag flow to BillGenerator.

---

## Phase 0 — Auth foundation (in detail)

### Server changes

**0.1 New endpoint: `POST /api/auth/login`** (REST counterpart to the existing Server Action). Body: `{username, password}`. Response on success: `{token: "<jwt>", user: {id, name, role}}`. On failure: `401 {error: "..."}`. Sets `auth-token` cookie too (for browser callers). Reuses the existing `generateToken()` and rate limit logic.

**0.2 Whitelist removed.** Bearer-token route bypass for `/api/bills` is no longer needed (iOS will use cookie auth via the existing JWT path). Keep the bearer logic in the upload endpoint as a deprecated fallback for now; remove later.

### iOS changes

**0.3 `LoginView.swift`** — username/password form. On submit, POST to `/api/auth/login`, store returned JWT in Keychain (key `authToken`), and dismiss to root.

**0.4 `Session` observable** — `@Observable` class injected via `@Environment`. Tracks `currentToken: String?`, `currentUser: User?`. Reads from Keychain on init. Provides `signIn(username:password:)` and `signOut()`.

**0.5 `APIClient` foundation** — wraps `URLSession`. Always sends `Cookie: auth-token=<jwt>` from Session. On `401`, signs out (token expired). All future iOS-side API calls go through this.

**0.6 Wire login into app entry** — `DurigoApp.body` shows `LoginView` if Session has no token, otherwise shows `Home()`.

### Testing

- iPhone 17 sim: Login → land on Bill Generator (default). Verify token stored.
- iPad Pro 13" sim: Login → split view, same flow.
- 401 from API → app returns to Login automatically.
- Logout → token cleared, returns to Login.

### Acceptance criteria
- [ ] `/api/auth/login` REST endpoint returns JWT
- [ ] iOS login form works against localhost (and later restaurant.local)
- [ ] After login, all API calls include `Cookie: auth-token=...`
- [ ] Logout clears Keychain
- [ ] iPhone + iPad both render the Login screen correctly
- [ ] No regression to Bill Generator (still works without internet, still produces PDFs)

---

## Phase 1 — Bill sync (revised)

After Phase 0 lands:
- `BillUploader` refactored to use `APIClient` (cookie auth) instead of bearer token
- `BillSyncSettings` view removed (login covers it)
- History view stays SwiftData-driven, with auto-pull on foreground via `APIClient.fetchBills()`
- Existing 6,740 bills on the iPad SwiftData are picked up by the pull (server has them; sync becomes a no-op upsert)

### Acceptance criteria
- [ ] iPad with 6,740 local bills + token → opens History → shows correct list, no duplicates
- [ ] Create bill in Bill Generator while offline → bill saved to SwiftData with `syncedAt = nil` → reconnects → syncs automatically → `syncedAt` populated
- [ ] Web dashboard at `/admin` reflects iOS-uploaded bill within ~1s of network being available

---

## What we explicitly are *not* doing
- Replacing the web app entirely
- Building a separate admin web for the Pi
- Offline writes for POS/KDS state (real-time only when online)
