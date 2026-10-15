# iOS / iPadOS / macOS QA Plan

The app's counterpart to the web app's two plans
(`restaurant-management/docs/qa/functional-test-plan.md` and `screen-review-plan.md`).
Part 1 checks that every feature works; part 2 reviews how each screen looks
and behaves on the device it's used on.

## How to run it

**Server.** Run the web app locally against a copy of the production
database, never the Pi itself:

```bash
cd ~/Developer/restaurant-management
createdb rm_qa && pg_restore --no-owner -d rm_qa ~/RestaurantBackups/<latest>.dump
DATABASE_URL=postgresql://localhost/rm_qa npx prisma migrate deploy
export QA_PASS=$(openssl rand -hex 12)
DATABASE_URL=postgresql://localhost/rm_qa node scripts/qa-seed.cjs   # qa-admin/-waiter/-kitchen/-cashier + QA10
DATABASE_URL=postgresql://localhost/rm_qa npm run dev
```

**App.** Use the `Durigo (Local)` scheme, which points at `http://127.0.0.1:3000`.
Check every row on all three platforms unless it says otherwise:

| Platform | Device | Who uses it |
|---|---|---|
| iPhone | iPhone 17 simulator, then a real phone | Waiters at tables |
| iPad | iPad Pro 13" simulator, then the counter iPad | Cashier, Bill Generator, kitchen display |
| Mac | This Mac (native macOS build, `platform=macOS`) | Owner: reports, admin, back-office billing |

**Automated tests.** 10 unit tests and 11 UI tests; the command is in
`IOS_FEATURE_PARITY_PLAN.md`. Rows marked 🤖 are covered by a test, and the
test's name is given.

**Priority.**
- **P0**: money, or something that stops service.
- **P1**: daily operations.
- **P2**: admin conveniences.

**Status.** ✅ passed (with when or how it was checked), ⚠️ known issue, blank = not run yet.

---

## Part 1: Functional checks

### 1. Sign-in, roles and platforms (P0)

| # | Check | Expected | Status |
|---|---|---|---|
| 1.1 | Sign in as each role | Lands on that role's first screen | ✅ simulator |
| 1.2 | Wrong password; 10 wrong in 15 minutes | Error; then locked for 5 minutes | ✅ 🤖 QAPlanUITests testWrongPasswordThenLockout (server's message; locked after 10, a throwaway username) |
| 1.3 | iPhone tabs per role | Admin: Dashboard, POS, Billing, Reports. Cashier: POS, Billing, Reports. Waiter: POS, Billing. Kitchen: Kitchen. Everything else under More | ✅ simulator; 🤖 AdminScreensUITests |
| 1.4 | iPad and Mac sidebar per role | Same screens as the iPhone tabs plus More, grouped | ✅ iPad simulator tour, each role (admin, waiter, cashier, kitchen); kitchen board hides the sidebar. Mac ✅ 15 Oct (unlocked): admin, waiter (POS, Billing, Reservations, Settings), cashier (+ Reports) and kitchen (board with the sidebar folded away) |
| 1.5 | Non-admin opens Settings | Account and Sign Out only; no Restaurant settings | ✅ 🤖 QAPlanUITests (waiter) |
| 1.6 | Admin deactivates a user who is signed in on a phone | The phone's next request signs it out | ✅ 🤖 testDeactivatedUserIsSignedOut |
| 1.7 | Sign out | Token revoked; Keychain cleared; back to login | ✅ 🤖 QAPlanUITests |
| 1.8 | Mac: launch, sign in, load tables | Works (needs the network entitlement) | ✅ 14 Oct, Mac |
| 1.9 | Wi-Fi off, then back on | Live indicator turns red, then green; data catches up without restarting the app | ✅ simulator, server stopped as a stand-in for Wi-Fi: indicator red within 20s, green again ~25s after it came back, no restart. Real Wi-Fi: ⏳ on a device |

### 2. Bill Generator (P0: what staff use today)

| # | Check | Expected | Status |
|---|---|---|---|
| 2.1 | Search the menu, including typos ("chiken") | Finds the item | ✅ 🤖 testShouldFilterMenuWithQuery (passed 15 Oct) |
| 2.2 | Add items, variants (Peg/Quarter/…), custom item, half portion | Line prices right; half of ₹155 = ₹78 | ✅ 🤖 testBillGeneratorBillMatchesItemsToMenu (passed 15 Oct) |
| 2.3 | Voice ordering | Recognised items added; mic permission prompt on first use (iPhone, iPad and Mac) | ⏳ needs a real device (microphone) |
| 2.4 | Pick table (or Parcel) and waiter, then Print | Preview pages; PDF generated; Share/Print works | ✅ 🤖 QAPlanUITests (table, waiter, print preview) |
| 2.5 | Receipt tax lines | CGST + SGST on food and soft drinks, VAT on liquor, taxable value; adds up to the total | ✅ 🤖 testRenderReceiptForReview + QAPlanUITests (₹200 liquor → VAT ₹36; ₹300 food → ₹7 + ₹7) |
| 2.6 | Custom item named after a drink ("Kingfisher pint", "Virgin Mojito", "Ginger chicken") | Kingfisher → VAT; the other two → GST | ✅ 🤖 testBillMathAllocateAndTaxClass (passed 15 Oct) |
| 2.7 | Receipt header | Durigo's details from settings; never the "Spice Garden" placeholders | ✅ 🤖 testRestaurantIdentityIgnoresPlaceholders (passed 15 Oct) |
| 2.8 | 20+ items | Several pages; totals and tax only on the last page; nothing overlaps | ✅ 🤖 testLongBillSplitsAcrossPages (13 on the last page, 19 on the others) |
| 2.9 | Print offline (Wi-Fi off) | Bill prints with GST/VAT from the cached rates; uploads when back online | ✅ simulator: bill printed with the server stopped (VAT ₹36, CGST ₹7 from cached rates) and uploaded once it was back, linked to QA Waiter. Fixed: the waiter list is now cached for offline (was a stale hardcoded list) |
| 2.10 | Upload | Bill appears on the web billing history and in the CA report with the same GST/VAT as printed | ✅ uploaded with table 9 and the waiter linked (14 Oct); GST/VAT on the web once marked paid: not yet checked |
| 2.11 | Customer phone and name on a bill; the waiter picked | Server links the bill to the waiter by id and to the customer by phone ("+91 …", spaces ignored); both show in the staff and customer reports | ✅ 🤖 QAPlanUITests (Bill Generator test checks the server) |
| 2.12 | Update over an existing install (bills saved before) | App opens; old bills still listed (store upgraded V4 → V5) | ✅ simulator (iPhone and iPad upgrade, iPad fresh install) |

### 3. Billing: Till and Bills (P0)

15 Oct redesign ("A · Till" with "B · Ledger" as Bills). The Billing tab opens on the Till (Waiting to pay); a segment switches to Bills (admins and cashiers; the ledger API refuses waiters) or, for waiters, to the Bill Generator's bills. The old bill history list is gone; its sync, filters and Regenerate live on in Bills and the Bill Generator detail.

| # | Check | Expected | Status |
|---|---|---|---|
| 3.1 | List pages through server bills; filter by status | Correct; pending count badge on the tab | ✅ 🤖 BillsPage + API checks 11.9/11.12; pending badge on the tab. Fixed: the list was empty on any device once a POS order had been paid (one unreadable bill failed the whole page); API check 11.12 |
| 3.2 | Mark a bill paid by cash, UPI or card | Saved; the server updates | ✅ 🤖 testBillAppearsLiveThenDiscountedAndPaid (UPI, checked on the server) |
| 3.3 | Discount on a bill (cashier/admin), percent or ₹ | Total updates; a waiter can't upload a discounted bill (the server refuses) | ✅ 🤖 same test (10% off, saved on the server); testWaiterSeesNoDiscountOnABill. Fixed: waiters no longer see Apply discount |
| 3.4 | Bill uploaded from another device | Appears live | ✅ 🤖 same test: appears within seconds of the upload |
| 3.5 | Duplicate a bill; reprint an old bill | Works | ✅ 🤖 testRegenerateAnOldBill (now Bills → the bill → Open bill → Regenerate). Fixed: Regenerate now opens the Bill Generator holding the bill (it used to leave you on the table grid) |
| 3.6 | Till: Waiting to pay | Tables asked for the bill first (amber tile, "Pedro · asked 6m ago"), then all served (blue), then cooking ("2 dishes cooking"), takeaways as P; live (SSE, debounced) and pull to refresh; "Nothing waiting to be paid" when empty. VoiceOver: "Table 12, ₹1,770, all served, Pedro" | ✅ iPhone 17 and iPad Pro 13" (portrait with sidebar: queue + bill-and-pad; sidebar hidden: three columns), light and dark, 15 Oct; 🤖 testTillPaysATableAndShowsTheReceipt checks the row's label |
| 3.7 | Till: pay a table | Bill header (Bill no · waiter · seated · N orders), lines, Items / Discount / Taxable value / CGST / SGST / VAT / To pay; pad: Cash · UPI · Card · Split (sheet) · other ways (Wallet); discount code or ₹ / % (cashier, admin); cash given Exact / next ₹100 / ₹500 / ₹2,000 with change; "Pay ₹x by UPI"; receipt with every order of the table, Print or share | ✅ iPad: own order on table 118 (2 orders' worth: Veg. Soup ×2 + Kingfisher), 10% off (−₹58), ₹600 cash given → change ₹78, paid ₹522, receipt listed both lines with VAT; server ledger matched (discount 58, total 522). 🤖 testTillPaysATableAndShowsTheReceipt (two orders on one table, ₹20 off, UPI, receipt lists both) |
| 3.8 | Bills (ledger) | Today / Yesterday / Pick dates (sheet); search (bill no, table, waiter, customer, dish); Filter menu (waiter, method, unpaid only, from the Bill Generator); cards Takings · N bills, Cash · UPI · Card, GST · VAT, Discounts (Unpaid on iPhone); "N waiting" strip opens the bill in the Till; rows with method pills (Unpaid in red, "Cash + UPI" for splits); iPad: table + detail side by side; iPhone: push | ✅ iPhone 17 and iPad Pro 13", light and dark; search "7659" found the split bill |
| 3.9 | Bill detail | Totals, tenders, Print / share receipt (orders fetched), Change method (admin, cashier); a split bill shows the server's refusal; Bill Generator bills: Mark paid (Cash / UPI / Card, never silently Cash) and Open bill (discount, Regenerate) | ✅ #7658 Cash → UPI from the iPhone (server ledger shows UPI); #7659 (split) → "A split bill was paid in parts; its methods can't be changed"; receipt printed from the ledger |
| 3.10 | Waiter | Billing shows Waiting and Bill Generator only (no Bills); app bills open their detail without discount | ✅ iPhone 17 as qa-waiter; 🤖 testWaiterSeesNoDiscountOnABill (also asserts no Bills segment) |
| 3.11 | Bill Generator bills not uploaded | Listed in Bills under "On this device, not uploaded" with Upload and Upload all; Sync All Unsynced in the toolbar's cloud menu; a changed but unsynced bill has a cloud mark on its row; totals are the bill's total after discount everywhere | ✅ code path; 🤖 testBillGeneratorBillShowsGSTAndVATAndUploads |

### 4. POS tables and ordering (P0)

| # | Check | Expected | Status |
|---|---|---|---|
| 4.1 | An order placed on another device | Table tile (total, seated time, dish progress) and the open bill update live | ✅ simulator |
| 4.2 | Take an order: categories, search, variants, quantity | Cart right; Send to Kitchen | ✅ 🤖 testTakeOrderWithCategorySearchAndQuantity (2 × Soda reached the server) |
| 4.3 | Per-item note | Shows on the cart line and in red on the kitchen card | ✅ simulator |
| 4.4 | Takeaway; delivery with name, phone and address | Delivery details reach the kitchen in the order note | ✅ simulator |
| 4.5 | Retry Send after the network drops | Exactly one order (idempotency key) | ✅ the key survives retries (only a changed cart gets a new one); the server side is API check 2.x |
| 4.6 | Merge and unmerge tables; order at a merged table | Secondary tables route to the primary | ✅ 🤖 testMergeAndUnmergeTables; merged tiles carry a link mark, a secondary tile with no orders of its own reads "→ Table 2" and opens the primary's bill; "Merged tables" under the floor lists each group with Unmerge (15 Oct floor redesign, iPhone 17 and iPad Pro 13", light and dark) |
| 4.7 | Reservation from a table's bill (Reserve on a free table); today's date | Saved; shown on the table's bill, and its time on the tile | ✅ 🤖 testReservationFromATableCard. Fixed: the booking now shows straight away |
| 4.8 | Manage tables: add, renumber, seats, out of service, delete | Works; can't take an occupied table out of service | ✅ 🤖 ManageTablesUITests |
| 4.9 | Extras on a cart line (extras button, for that category) | Line price adds the extra; "+ Extra cheese" on the order, kitchen card, item details and ticket | ✅ 🤖 QAPlanUITests (iPhone and iPad) |
| 4.10 | Cancel a whole order from the order screen, with a reason | Leaves the bill and the kitchen; table freed when nothing else is open; hidden for staff once food is served (admins still can) | ✅ 🤖 QAPlanUITests (iPhone and iPad) |
| 4.11 | Takeaway with an optional customer phone and name; delivery customer and address | Order linked to the customer found or created by phone; delivery address saved on the customer | ✅ 🤖 QAPlanUITests testTakeawayWithCustomer (link checked in the database) |
| 4.12 | Floor (15 Oct redesign, "Floor + Counter"): tiles by section, filter chips All / Seated / Bill asked / Free, summary "N of M seated · ₹ open", Live, ⋯ menu (Takeaway, Delivery, Merge, Manage), Parcel tile | 4 tiles across on iPhone, about 100pt tiles on iPad and Mac; tile shows seated time, total, waiter (not on iPhone) and one progress segment per dish (to do amber, cooking blue, ready teal, served grey); tap selects with a teal ring | ✅ iPhone 17 and iPad Pro 13", light and dark (screenshots) |
| 4.16 | iPhone: tap a table; Take order / Reserve / + Items from its bill | The bill is the system sheet (half height, drag handle, floor still usable behind it; short for a free table). Take order and Reserve open as their own sheets, and when they finish or are cancelled the table's bill comes back with the new order or booking. The kitchen note is a labelled two-line box. | ✅ iPhone 17 15 Oct; 🤖 QAPlanUITests testTakeOrderWithCategorySearchAndQuantity, testReservationFromATableCard |
| 4.13 | The selected table's bill | iPad/Mac: a 380pt panel beside the floor ("Tap a table to see its bill" when none); iPhone: a card at the bottom, pulled up (or grabber tapped) for every line. Lines grouped To do / Cooking / Ready / Served, totals by BillMath (food + GST, liquor + VAT, total tax included); + Items, Bill (asks for the bill), Pay (payment screen); free: Take order, Reserve; reserved: Seat & take order; out of service: Back in service | ✅ iPhone 17 (card collapsed and expanded, dark) and iPad Pro 13" (panel, light and dark) |
| 4.14 | Adding items on iPad/Mac | Table strip to switch tables (a dot marks a table with lines not sent), categories with counts, menu cards with variant chips and an in-cart count, live bill with "Not sent" lines, totals, Send N to kitchen and Bill · Pay. iPhone keeps the list with a bar "₹total · N items · N not sent" and Send N to kitchen | ✅ iPad Pro 13" (light and dark, variant chip added Smirnoff · Peg, VAT line appeared), iPhone 17 (dark, two items added, bar showed ₹440 · 12 items · 2 not sent) |
| 4.15 | Bill Generator from POS | Quiet document button top right of the floor opens it; "Floor" goes back; Regenerate still lands on it | ✅ 🤖 testBillGeneratorBillShowsGSTAndVATAndUploads |

### 5. POS payment (P0, money)

| # | Check | Expected | Status |
|---|---|---|---|
| 5.1 | Breakdown for food + liquor | GST and VAT match the web for the same table | ✅ simulator (₹1,140 → GST ₹24, VAT ₹115) |
| 5.2 | Discount code QA10; invalid code | 10% off and taxes recomputed; invalid code shows the server's reason | ✅ 🤖 POSPaymentUITests |
| 5.3 | ₹ discount as cashier; waiter sees no discount controls | As described | ✅ 🤖 testCashierRupeeDiscount (₹10 off the total) + testWaiterSeesNoDiscountOnABill |
| 5.4 | Split 2/3/4 ways and by hand; parts don't add up | Done and Pay disabled until they add up | ✅ 🤖 POSPaymentUITests (15 Oct: the floor's Pay uses the Till's pay pad; Split opens the split editor as a sheet) |
| 5.5 | Bill changed on another device before paying | Refused with "The bill changed from ₹X to ₹Y"; screen reloads | ✅ simulator |
| 5.6 | Receipt after paying | Items, discount, taxes, total, "Paid by …"; print or share as PDF | ✅ 🤖 POSPaymentUITests |
| 5.7 | Server record | Payment, discount code, split tenders and GST/VAT stored | ✅ checked in the database |

### 6. Kitchen (P0)

| # | Check | Expected | Status |
|---|---|---|---|
| 6.1 | New order arrives | Appears live; chime plays | ✅ trigger on simulator; ⚠️ chime not yet heard on a device |
| 6.2 | Auto-print with a printer chosen | One ticket per order, no dialog (iPad); default printer (Mac) | ⚠️ ⏳ needs the real printer |
| 6.3 | Auto-print with no printer chosen | Clear message, no crash | ✅ simulator |
| 6.4 | Print button on a card | Prints, or asks for a printer | ✅ 🤖 testKitchenCardPrint (print sheet on the simulator). Fixed: the card's ⋯ and print buttons were 14pt |
| 6.5 | Ticket layout on 80mm paper | Table/type, number, IST time, notes in capitals, no cancelled items | ✅ 🤖 testRenderKitchenTicketForReview |
| 6.6 | Change status: phases, per item, drag and drop on iPad | Saved; other screens update | ✅ 🤖 testKitchenPhaseItemStatusAndCook (phase, item Ready, on the server); iPad drag To do → Preparing saved (simulator, 15 Oct) |
| 6.7 | Assign a cook | Saved | ✅ 🤖 same test (cook saved) |
| 6.8 | Elapsed time colours | Yellow after 15 minutes, red after 30 | ✅ simulator: 20m and 28m yellow, over 30m red. Fixed: confirmed orders made a second "To do" section on iPhone |
| 6.9 | "Cancel order…" from the ⋯ button on a kitchen card | Card leaves the board; hidden for staff once food is served (admins still see it) | ✅ 🤖 QAPlanUITests testKitchenCancelsAnOrder (iPhone and iPad) |

### 7. Reservations (P1)

| # | Check | Expected | Status |
|---|---|---|---|
| 7.1 | New reservation with no table; for later today; in the past | Saved; saved; refused with a reason | ✅ 🤖 testReservationCreateRefusePastAndStatuses ("That time has already passed") |
| 7.2 | Confirm, arrived, complete, no-show, cancel | Status changes; never frees a table with diners | ✅ 🤖 same test (Confirmed, Arrived, Completed on the server); the table rule is API check 6.x |

### 8. Reports (P1, CA report P0)

| # | Check | Expected | Status |
|---|---|---|---|
| 8.1 | Overview for each period | Matches the web `/reports` | ✅ same numbers as the web /reports (₹1,08,814 / 110 orders / ₹1,067 for 7 days, 15 Oct) |
| 8.2 | CA report for last month | Same totals and GST/VAT as the web; Copy and Share work (on Mac too) | ✅ same server function as the web CA page; Copy confirms and Share opens (tour). Mac ✅: Copy for CA confirms ("Copied"); Share opens the system share menu (Mail, Messages, Notes…) — 🤖 MacKeyboardUITests, 15 Oct |
| 8.3 | Sales, Performance, Customers, Staff, Inventory | Load; match the web | ✅ all five load (tour). Fixed: Performance failed to load ("data couldn't be read") and its 7d/30d ranges showed today; removed tiles that were always 0 |

### 9. Admin (P1/P2)

| # | Check | Expected | Status |
|---|---|---|---|
| 9.1 | Menu: items, categories (FOOD/BEVERAGE/ALCOHOL), variant templates | Create, edit, delete; POS and Bill Generator pick them up | ✅ 🤖 testNewMenuItemShowsInPOS |
| 9.2 | Modifiers, discounts, users, inventory CRUD | Works | ✅ 🤖 AdminScreensUITests (users, discounts, modifiers, inventory) (passed 15 Oct) |
| 9.3 | Settings: GST %, VAT %, VAT TIN; a blank or out-of-range rate | Saved; refused with the field named | ✅ 🤖 testSettingsRefusesAnOutOfRangeRate ("GST rate …"). Fixed: fields now keep their labels; settings nothing reads are hidden, as on the web |
| 9.4 | Settings change → next receipt | New rates and header on the next bill | ✅ settings (name, address, GSTIN, VAT TIN, rates) are fetched and cached for the next bill; 🤖 testRestaurantIdentityIgnoresPlaceholders |

---

## Part 2: Screen review

### Checklist for every screen (on iPhone, iPad and Mac)

**Layout**
- [x] Fits the screen: no clipped text; long item names wrap; ₹1,00,000 totals fit. ✅ iPhone 17 and iPad Pro 13" tours, 15 Oct (₹1,42,569 fits)
- [x] iPad uses the width (no stretched phone layout); Mac windows resize sensibly and nothing hides behind the toolbar. ✅ iPad; Mac ⏳

**Touch and input**
- [x] Tap targets at least 44pt, and the main action reachable with a thumb. ✅ fixed the 14–20pt ones found (kitchen ⋯/print, item chips, cart +/−, unmerge); some secondary chips are ~32–36pt
- [x] Mac: keyboard (Return submits, Esc cancels) and pointer hover work. ✅ 🤖 MacKeyboardUITests: Esc closes the new-reservation sheet (15 Oct); login Return moves to the password then signs in (`onSubmit`); every sheet's Cancel/Save are `.cancellationAction`/`.confirmationAction`

**States**
- [x] Loading, empty and error states exist and offer a way out. ✅ ("No bills yet", "No upcoming reservations", errors in plain words)
- [x] Offline is shown on live screens. ✅ POS and kitchen Live indicator (1.9)

**Text and numbers**
- [x] Money as ₹ with Indian grouping and no paise; times in IST. ✅ one `rupees` format everywhere (🤖 testRupeesAreWholeWithIndianGrouping)
- [x] Wording matches the web (Bill, Table, Served…). ✅

**Theme and accessibility**
- [x] Dark mode, and the largest Dynamic Type size, still readable. ✅ dark mode on iPhone and iPad. Text size checked 15 Oct up to the largest accessibility size: the login screen now wraps and scrolls at every size; the working screens grow up to xxxLarge (the largest standard size) and stop there, because at accessibility sizes the table cards, kitchen columns and bill rows split words (*assumption:* that cap is right for dense staff screens). At xxxLarge the kitchen card shows the table on its own bold line instead of dropping it
- [x] VoiceOver: icon buttons have labels; order makes sense. ✅ labels added where missing (reserve, unmerge, cart +/−)

**Safety**
- [x] Destructive actions confirm; errors are in plain words. ✅

### Screen by screen

| Screen | Review focus | Status |
|---|---|---|
| Login | Brand panel on iPad/Mac; keyboard Return to sign in; error placement | ✅ iPhone (lockout message, 🤖 login-locked-out screenshot). Mac ✅ 15 Oct. |
| Dashboard | Numbers match the web; refresh | ✅ iPhone and iPad, light and dark; same numbers as the web. Mac ✅ 15 Oct. **Redesigned 15 Oct ("Service night"):** same figures as the web dashboard from `/api/admin/dashboard/service`, reloads on live events and every minute; one column on iPhone, two beside the iPad sidebar, three when wide. ✅ iPhone 17 and iPad Pro 13", light and dark (table numbers ungrouped, e.g. 1043). Oldest ticket card: table, wait, dishes still to come, cook ("Not assigned" when nobody), waiter ✅ iPad. ✅ Mac 15 Oct evening: dashboard, POS floor, Till and Bills checked in light and dark (window screenshots). `MacKeyboardUITests/testDashboardOnMacLightAndDark` still can't open a window when run from the agent's shell (the app opens one normally when launched with `open`), so that test needs running from Xcode. |
| POS floor (redesigned 15 Oct) | Readable from arm's length on iPad; Live indicator; merged groups; the ⋯ menu (takeaway, delivery, merge, manage); bill beside the floor | ✅ iPhone 17 and iPad Pro 13", light and dark: compact tiles, filter chips, section labels, bill panel / bottom card. Mac: builds; see 4.12 |
| Take order | Taps for a typical order; cart always visible; note editor; delivery fields | ✅ iPhone (🤖 tour + ordering test). Fixed: cart +/− were 17pt and unlabelled; category chips taller. Redesigned 15 Oct: three columns on iPad/Mac (4.14), summary bar on iPhone ✅ iPhone 17 and iPad Pro 13", light and dark |
| Order detail and payment | Amount due is the biggest thing; breakdown readable; split rows on iPhone width | ✅ iPhone, Mac |
| Paid receipt | Looks like the printed bill; Share/Print reachable | ✅ iPhone |
| Manage tables, merge tables, reservation dialog | Sheets on iPhone; Mac sheet sizes | ✅ iPhone (🤖 merge and reservation-from-card tests). Mac ✅ 15 Oct. |
| Bill Generator | Fast with one hand; table and waiter pickers; empty state | ✅ iPhone and iPad; works offline with the cached waiter list. Mac ✅ 15 Oct. |
| Bill preview and receipt | Durigo's header; tax lines; QR; multi-page | ✅ rendered; ✅ on iPhone the page was 420pt on a 402pt screen and its header hid behind the back button; it now scales to fit (14 Oct) |
| Voice ordering | Permission flow; match picker | ⏳ needs a real device (microphone) |
| Billing history and bill detail | Status chips; filters; discount sheet | ✅ iPhone and iPad, light and dark. Fixed: the list was empty once a POS order was paid; bill lines read "2× Soda ₹40" (was "2.0 Soda 40"); waiters don't see Apply discount. Mac ✅ 15 Oct. |
| Kitchen (iPhone list, iPad kanban, Mac) | From 1–2 m: order number, table, notes; columns fit; drag on iPad; toolbar alert menu | ✅ iPhone list and iPad kanban (portrait now shows all four columns with the sidebar hidden; drag tested); old order numbers shortened to 4 digits; chips and ⋯ big enough to hit. One "To do" section on iPhone (was two). Mac ✅ 15 Oct. |
| Kitchen ticket | Thermal-printer legibility | ✅ rendered |
| Reservations | Today/upcoming; form; detail sheet | ✅ iPhone (🤖 create, refuse past, statuses). Time field gets the number keyboard. Mac ✅ 15 Oct. |
| Reports, CA and the five breakouts | Charts legible in dark mode; Copy for CA | ✅ iPhone tour (all six screens); Copy for CA confirms; Performance loads now; money is whole rupees with Indian grouping everywhere (was ₹1,08,814.00 in places, ₹102610 in others). Mac ✅ 15 Oct. |
| Menu editor (items, categories, variants) | Long lists; forms on iPhone | ✅ iPhone and iPad (🤖 new item test). Mac ✅ 15 Oct. |
| Modifiers, Discounts, Inventory, Users | Forms; destructive confirmations | ✅ iPhone and iPad (🤖 AdminScreensUITests). Mac ✅ 15 Oct. |
| Settings and Restaurant settings | Percent fields; field labels (the form shows values without labels) | ✅ every field keeps its label (LabeledContent); only what reaches a bill (as on the web). 🤖 out-of-range GST refused. Mac ✅ 15 Oct. |
| Skeleton loaders (15 Oct) | While a screen's data loads it draws its own layout with sample data, redacted, with a shimmer (`.skeleton(_:)` in `Shared/Skeleton.swift`, samples in `Shared/SampleData.swift`); no shimmer with Reduce Motion; read as one "Loading" element; never on pull-to-refresh of loaded data. Spinners stay only on buttons and short actions (sign in, pay, send, save, PDF) | ✅ iPhone 17 and iPad Pro 13", light and dark, with `--skeleton-preview` (DEBUG: data never finishes loading): dashboard, POS floor, Till (mode picker stays live), Bills (summary, rows, detail), Reports and its six breakouts, Menu editor, Kitchen, Users, Discounts, Modifiers, Inventory, Reservations, Restaurant settings; without the flag real data replaces them. 🤖 `testSkeletonSamplesDecode` |

### Order of work

1. Service screens on the real devices during a mock service: Bill Generator, POS, payment, Kitchen with the real printer.
2. Cashier and owner: Billing history, Reports, CA report, Reservations.
3. Admin screens, on Mac first.

## Run of 15 Oct: found and fixed

On the iPhone 17 and iPad Pro 13" simulators against the local QA server.
*Assumption:* stopping the local server stands in for the Wi-Fi going off.

- **Bill history went empty** on every device once a POS order had been paid: the
  server listed POS orders (ids "pos-order:…", not UUIDs) and one unreadable bill
  failed the whole page. The server now lists only app bills, and the app skips
  any bill it can't read (🤖 testBillsPageSkipsAnUnreadableBill, API check 11.12).
- **Performance report** didn't load (a decimal percentage, a missing revenue
  field), and its 7-day and 30-day ranges showed today (🤖
  testPerformanceReportDecodesTheServersShape, API check 11.13).
- **Money** is whole rupees with Indian grouping everywhere, whatever the
  device's region (it was ₹500.00 in places and ₹102610 in others).
- **Kitchen**: iPad portrait fits four columns with the sidebar hidden; the ⋯ and
  print buttons and item chips are big enough to hit; old order numbers shortened.
- **Waiters** no longer see Apply discount on a bill (the server refused it anyway).
- **Regenerate** opens the Bill Generator with the bill; a reservation booked from a
  table card shows on it at once; the Bill Generator keeps the last waiter list
  for offline use.
- **Restaurant settings** keep their field labels and show only what reaches a bill.

**Before a full UI test run**, cancel leftover test orders on the local QA
server (dozens of open QA orders make the kitchen board re-render constantly and
the kitchen cancel test then loses its alert), and put one table in "bill
requested" for `POSPaymentUITests`.

**Re-running the screen review.** `ScreenTourUITests` opens every screen as the
admin on iPhone and attaches screenshots (`xcrun xcresulttool export attachments`);
on iPad, launch each screen with `--auto-signin=qa-<role>:… --start-tab=<screen>`
and `xcrun simctl io <device> screenshot`, light and dark
(`xcrun simctl ui <device> appearance dark`).

**Still open (needs you or real hardware).** Mac screen review (the Mac must be
unlocked for screenshots; the build runs), the real printer (6.2), voice ordering
on a device (2.3), the chime on a device (6.1), real Wi-Fi drop on the counter iPad.

## Mac review, 15 Oct (screen locked)

The Mac was locked, so the running app couldn't be screenshotted. Instead the
unit tests now run on the Mac (the app skips the Keychain as a test host) and
render screens offscreen with the Mac's own layout and fonts:

| Screen | Mac result |
|---|---|
| Login (1100×700 and 402 wide) | ✅ brand panel beside the form when wide, stacked when narrow (text fields can't be drawn offscreen; they show as placeholders) |
| Receipt / bill preview | ✅ after a fix: the Mac app didn't load Durigo's fonts (macOS ignores `UIAppFonts`), so the name printed in a plain font and ran into the GSTIN line. `ATSApplicationFontsPath` added |
| Long bill, two pages | ✅ |
| Kitchen ticket (80mm) | ✅ |
| Bill detail | ✅ header, discount and total; found and fixed: totals cut paise instead of rounding (₹1,017.50 showed ₹1,017, not ₹1,018) here and in 14 other places |
| Every other screen | ✅ on the running app once the Mac was unlocked (below) |

All 15 unit tests pass on the Mac as well as on the iPhone simulator.

## Mac review, 15 Oct (unlocked, running app)

Screenshots of the running Mac app, window maximised, every sidebar screen as the
admin, plus waiter, cashier and kitchen: Dashboard, POS tables (6 columns), Kitchen
board (4 columns, Live), Billing (whole rupees), Reservations and its sheet, Menu,
Modifiers, Discounts, Inventory, Users, Reports, CA report (Copy confirms),
Settings and Restaurant settings, Login. Fixed on the way:
- **Forms** used the Mac's default style (labels right-aligned in a narrow column,
  section titles as plain text, floating mid-window): every form is now grouped,
  as on iOS (`.formStyle(.grouped)` on the window)
- **Labels printed twice** on Mac fields ("Name Name Durigo's", "0 5 %"): 16
  fields hide their own label where a row label is already shown

**Deploys.** The Pi serves only the web app (`restaurant-management`); this repo
is never deployed there. Each iOS/Mac batch was confirmed by building for iOS and
Mac and reinstalling on both simulators.

## Mac pass (only the bits that need you)

Share on the CA report (8.2) and Esc closing a sheet are covered by
`MacKeyboardUITests` (✅ passed 15 Oct with you at the Mac). macOS asks for your
Touch ID or password once before UI tests can drive the Mac, so run it at the Mac:

```bash
TEST_RUNNER_QA_PASS=… xcodebuild -project Durigo.xcodeproj -scheme "Durigo (Local)" -configuration "Debug Local" -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -only-testing:DurigoUITests/MacKeyboardUITests test
```


Why it's open: the Mac was locked (`IOConsoleLocked = Yes`) for the whole run,
so window screenshots failed and the Mac test runner hung at the keychain
prompt a locally signed test build raises. The Mac build itself succeeds, and
the unit tests now compile for macOS too (rendering helper works with NSImage).

With the Mac unlocked:
1. `xcodebuild … -destination 'platform=macOS,arch=arm64' -only-testing:DurigoTests test`
   (answer the keychain prompt once: Always Allow).
2. Open the app, sign in as each role, and check rows 1.4, 1.8, 8.2 (Copy and
   Share), the keyboard row (Return signs in and saves, Esc closes sheets) and
   the screen-by-screen table's Mac column. A signed release build won't show the
   keychain prompt.

### Largest text (xxxLarge, the app's cap), 15 Oct evening

| Screen | Result |
|---|---|
| Dashboard (iPhone, iPad) | ✅ fits; the pace chart's hour labels now sit under the line instead of over it |
| POS floor (iPhone, iPad) | ✅ after a fix: tiles are 3 across on iPhone (4 at normal sizes) and wider on iPad, and the seated time moves to its own line so table numbers, times and "→ Table N" are never cut off |
| Billing Till (iPhone, iPad) | ✅ fits; rows wrap to two lines |
