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
| 1.2 | Wrong password; 10 wrong in 15 minutes | Error; then locked for 5 minutes | |
| 1.3 | iPhone tabs per role | Admin: Dashboard, POS, Billing, Reports. Cashier: POS, Billing, Reports. Waiter: POS, Billing. Kitchen: Kitchen. Everything else under More | ✅ simulator; 🤖 AdminScreensUITests |
| 1.4 | iPad and Mac sidebar per role | Same screens as the iPhone tabs plus More, grouped | |
| 1.5 | Non-admin opens Settings | Account and Sign Out only; no Restaurant settings | ✅ 🤖 QAPlanUITests (waiter) |
| 1.6 | Admin deactivates a user who is signed in on a phone | The phone's next request signs it out | |
| 1.7 | Sign out | Token revoked; Keychain cleared; back to login | ✅ 🤖 QAPlanUITests |
| 1.8 | Mac: launch, sign in, load tables | Works (needs the network entitlement) | ✅ 14 Oct, Mac |
| 1.9 | Wi-Fi off, then back on | Live indicator turns red, then green; data catches up without restarting the app | |

### 2. Bill Generator (P0: what staff use today)

| # | Check | Expected | Status |
|---|---|---|---|
| 2.1 | Search the menu, including typos ("chiken") | Finds the item | 🤖 testShouldFilterMenuWithQuery |
| 2.2 | Add items, variants (Peg/Quarter/…), custom item, half portion | Line prices right; half of ₹155 = ₹78 | 🤖 testBillGeneratorBillMatchesItemsToMenu |
| 2.3 | Voice ordering | Recognised items added; mic permission prompt on first use (iPhone, iPad and Mac) | |
| 2.4 | Pick table (or Parcel) and waiter, then Print | Preview pages; PDF generated; Share/Print works | ✅ 🤖 QAPlanUITests (table, waiter, print preview) |
| 2.5 | Receipt tax lines | CGST + SGST on food and soft drinks, VAT on liquor, taxable value; adds up to the total | ✅ 🤖 testRenderReceiptForReview + QAPlanUITests (₹200 liquor → VAT ₹36; ₹300 food → ₹7 + ₹7) |
| 2.6 | Custom item named after a drink ("Kingfisher pint", "Virgin Mojito", "Ginger chicken") | Kingfisher → VAT; the other two → GST | 🤖 testBillMathAllocateAndTaxClass |
| 2.7 | Receipt header | Durigo's details from settings; never the "Spice Garden" placeholders | 🤖 testRestaurantIdentityIgnoresPlaceholders |
| 2.8 | 20+ items | Several pages; totals and tax only on the last page; nothing overlaps | |
| 2.9 | Print offline (Wi-Fi off) | Bill prints with GST/VAT from the cached rates; uploads when back online | |
| 2.10 | Upload | Bill appears on the web billing history and in the CA report with the same GST/VAT as printed | ✅ uploaded with table 9 and the waiter linked (14 Oct); GST/VAT on the web once marked paid: not yet checked |

### 3. Billing history (P0)

| # | Check | Expected | Status |
|---|---|---|---|
| 3.1 | List pages through server bills; filter by status | Correct; pending count badge on the tab | |
| 3.2 | Mark a bill paid by cash, UPI or card | Saved; the server updates | |
| 3.3 | Discount on a bill (cashier/admin), percent or ₹ | Total updates; a waiter can't upload a discounted bill (the server refuses) | |
| 3.4 | Bill uploaded from another device | Appears live | |
| 3.5 | Duplicate a bill; reprint an old bill | Works | |

### 4. POS tables and ordering (P0)

| # | Check | Expected | Status |
|---|---|---|---|
| 4.1 | An order placed on another device | Table card updates live | ✅ simulator |
| 4.2 | Take an order: categories, search, variants, quantity | Cart right; Send to Kitchen | |
| 4.3 | Per-item note | Shows on the cart line and in red on the kitchen card | ✅ simulator |
| 4.4 | Takeaway; delivery with name, phone and address | Delivery details reach the kitchen in the order note | ✅ simulator |
| 4.5 | Retry Send after the network drops | Exactly one order (idempotency key) | |
| 4.6 | Merge and unmerge tables; order at a merged table | Secondary tables route to the primary | |
| 4.7 | Reservation from a table card; today's date | Saved; shown on the card | |
| 4.8 | Manage tables: add, renumber, seats, out of service, delete | Works; can't take an occupied table out of service | ✅ 🤖 ManageTablesUITests |
| 4.9 | Extras on a cart line (extras button, for that category) | Line price adds the extra; "+ Extra cheese" on the order, kitchen card, item details and ticket | ✅ 🤖 QAPlanUITests (iPhone and iPad) |
| 4.10 | Cancel a whole order from the order screen, with a reason | Leaves the bill and the kitchen; table freed when nothing else is open; hidden for staff once food is served (admins still can) | ✅ 🤖 QAPlanUITests (iPhone and iPad) |

### 5. POS payment (P0, money)

| # | Check | Expected | Status |
|---|---|---|---|
| 5.1 | Breakdown for food + liquor | GST and VAT match the web for the same table | ✅ simulator (₹1,140 → GST ₹24, VAT ₹115) |
| 5.2 | Discount code QA10; invalid code | 10% off and taxes recomputed; invalid code shows the server's reason | ✅ 🤖 POSPaymentUITests |
| 5.3 | ₹ discount as cashier; waiter sees no discount controls | As described | |
| 5.4 | Split 2/3/4 ways and by hand; parts don't add up | Pay disabled until they add up | ✅ 🤖 POSPaymentUITests |
| 5.5 | Bill changed on another device before paying | Refused with "The bill changed from ₹X to ₹Y"; screen reloads | ✅ simulator |
| 5.6 | Receipt after paying | Items, discount, taxes, total, "Paid by …"; print or share as PDF | ✅ 🤖 POSPaymentUITests |
| 5.7 | Server record | Payment, discount code, split tenders and GST/VAT stored | ✅ checked in the database |

### 6. Kitchen (P0)

| # | Check | Expected | Status |
|---|---|---|---|
| 6.1 | New order arrives | Appears live; chime plays | ✅ trigger on simulator; ⚠️ chime not yet heard on a device |
| 6.2 | Auto-print with a printer chosen | One ticket per order, no dialog (iPad); default printer (Mac) | ⚠️ not yet on the real printer |
| 6.3 | Auto-print with no printer chosen | Clear message, no crash | ✅ simulator |
| 6.4 | Print button on a card | Prints, or asks for a printer | |
| 6.5 | Ticket layout on 80mm paper | Table/type, number, IST time, notes in capitals, no cancelled items | ✅ 🤖 testRenderKitchenTicketForReview |
| 6.6 | Change status: phases, per item, drag and drop on iPad | Saved; other screens update | |
| 6.7 | Assign a cook | Saved | |
| 6.8 | Elapsed time colours | Yellow after 15 minutes, red after 30 | |
| 6.9 | "Cancel order…" from the ⋯ button on a kitchen card | Card leaves the board; hidden for staff once food is served (admins still see it) | ✅ 🤖 QAPlanUITests testKitchenCancelsAnOrder (iPhone and iPad) |

### 7. Reservations (P1)

| # | Check | Expected | Status |
|---|---|---|---|
| 7.1 | New reservation with no table; for later today; in the past | Saved; saved; refused with a reason | |
| 7.2 | Confirm, arrived, complete, no-show, cancel | Status changes; never frees a table with diners | |

### 8. Reports (P1, CA report P0)

| # | Check | Expected | Status |
|---|---|---|---|
| 8.1 | Overview for each period | Matches the web `/reports` | |
| 8.2 | CA report for last month | Same totals and GST/VAT as the web; Copy and Share work (on Mac too) | |
| 8.3 | Sales, Performance, Customers, Staff, Inventory | Load; match the web | 🤖 (Performance) testReportsPerformanceSubpageLoads |

### 9. Admin (P1/P2)

| # | Check | Expected | Status |
|---|---|---|---|
| 9.1 | Menu: items, categories (FOOD/BEVERAGE/ALCOHOL), variant templates | Create, edit, delete; POS and Bill Generator pick them up | |
| 9.2 | Modifiers, discounts, users, inventory CRUD | Works | 🤖 AdminScreensUITests (users, discounts, modifiers, inventory) |
| 9.3 | Settings: GST %, VAT %, VAT TIN; a blank or out-of-range rate | Saved; refused with the field named | |
| 9.4 | Settings change → next receipt | New rates and header on the next bill | |

---

## Part 2: Screen review

### Checklist for every screen (on iPhone, iPad and Mac)

**Layout**
- [ ] Fits the screen: no clipped text; long item names wrap; ₹1,00,000 totals fit
- [ ] iPad uses the width (no stretched phone layout); Mac windows resize sensibly and nothing hides behind the toolbar

**Touch and input**
- [ ] Tap targets at least 44pt, and the main action reachable with a thumb
- [ ] Mac: keyboard (Return submits, Esc cancels) and pointer hover work

**States**
- [ ] Loading, empty and error states exist and offer a way out
- [ ] Offline is shown on live screens

**Text and numbers**
- [ ] Money as ₹ with Indian grouping and no paise; times in IST
- [ ] Wording matches the web (Bill, Table, Served…)

**Theme and accessibility**
- [ ] Dark mode, and the largest Dynamic Type size, still readable
- [ ] VoiceOver: icon buttons have labels; order makes sense

**Safety**
- [ ] Destructive actions confirm; errors are in plain words

### Screen by screen

| Screen | Review focus | Status |
|---|---|---|
| Login | Brand panel on iPad/Mac; keyboard Return to sign in; error placement | |
| Dashboard | Numbers match the web; refresh | |
| POS tables grid | Readable from arm's length on iPad; Live indicator; merged groups; the + menu (takeaway, delivery, merge, manage) | |
| Take order | Taps for a typical order; cart always visible; note editor; delivery fields | |
| Order detail and payment | Amount due is the biggest thing; breakdown readable; split rows on iPhone width | ✅ iPhone, Mac |
| Paid receipt | Looks like the printed bill; Share/Print reachable | ✅ iPhone |
| Manage tables, merge tables, reservation dialog | Sheets on iPhone; Mac sheet sizes | |
| Bill Generator | Fast with one hand; table and waiter pickers; empty state | |
| Bill preview and receipt | Durigo's header; tax lines; QR; multi-page | ✅ rendered; ✅ on iPhone the page was 420pt on a 402pt screen and its header hid behind the back button; it now scales to fit (14 Oct) |
| Voice ordering | Permission flow; match picker | |
| Billing history and bill detail | Status chips; filters; discount sheet | |
| Kitchen (iPhone list, iPad kanban, Mac) | From 1–2 m: order number, table, notes; columns fit; drag on iPad; toolbar alert menu | |
| Kitchen ticket | Thermal-printer legibility | ✅ rendered |
| Reservations | Today/upcoming; form; detail sheet | |
| Reports, CA and the five breakouts | Charts legible in dark mode; Copy for CA | |
| Menu editor (items, categories, variants) | Long lists; forms on iPhone | |
| Modifiers, Discounts, Inventory, Users | Forms; destructive confirmations | |
| Settings and Restaurant settings | Percent fields; field labels (the form shows values without labels) | ⚠️ unlabeled fields |

### Order of work

1. Service screens on the real devices during a mock service: Bill Generator, POS, payment, Kitchen with the real printer.
2. Cashier and owner: Billing history, Reports, CA report, Reservations.
3. Admin screens, on Mac first.
