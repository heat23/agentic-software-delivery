# Frontend Integration Patterns Reference

_Last reviewed: 2026-08-03 (deferred-findings closure: added the missing Inertia v2 `merge()`/`deepMerge()` "Merging Props" subsection — verified `ResponseFactory::merge()`/`::deepMerge()`, `MergeProp`/`Mergeable`, and the partial-reload-only merge gate directly against the installed `inertiajs/inertia-laravel` + `@inertiajs/core` v2.3.26 source; added a dated re-verify callout on the Next.js 13 RSC claim noting Next 16 is current, off-stack, retained for contrast only. Prior fabricated-API sweep 2026-08-02)_

Deep patterns for React Server Components, Inertia.js form/data handling, and real-time WebSocket integration. These patterns are shallow or absent in the current skill ecosystem and require dedicated reference material.

**Design conformance:** any rendered markup copied from these skeletons must conform to `_v-design.md § Design System Application Order` — canonical tokens/semantic utilities (never raw palette or hex), `LoadingButton` for async actions, `<InputError>` per form field. The skeletons below show wiring, not final styling.

---

## Section 1: React Server Components (RSC)

React Server Components decouple data fetching and business logic (server) from interactive UI (client). This pattern is native to Next.js 13+ App Router but requires careful boundary management.

> **[dated 2026-08-03 — re-verify before relying on this]** Next.js 16 is the current major as of
> this writing: Turbopack is the default bundler, `use cache`/Cache Components is the current
> data-caching model, and Partial Prerendering (PPR) is the current rendering strategy layered on
> top of the same Server/Client Component split this section describes. This section is **retained
> for contrast with Inertia only** — this operator's stack is Laravel + Inertia, not Next.js, and
> nothing here should be built against. If a project ever does adopt Next.js, re-verify every API in
> this section against the installed `next` version first; do not extend it from training-data memory.

### When to Use RSC vs Client Components

**Server Components (default):**
- Fetch sensitive data (API keys, tokens never leave server)
- Query databases directly without API layer
- Use server-only packages (`node:fs`, `node:crypto`)
- Static rendering for SEO (product pages, blogs, docs)
- Large dependency trees that don't need interactivity
- Reduce initial JS bundle by offloading logic

**Client Components (`'use client'`):**
- Interactivity needed (onClick, onChange, animations, form submission)
- Browser APIs (localStorage, geolocation, IntersectionObserver)
- React hooks (useState, useEffect, useContext)
- Event listeners and real-time subscriptions
- Minimize client component surface area; use composition to keep boundaries thin

### Server Component Patterns

**Async components & data fetching:**
```javascript
// Direct DB access in server component
export default async function Posts({ limit = 10 }) {
  const posts = await db.query('SELECT * FROM posts LIMIT ?', [limit])
  return <PostList items={posts} />
}
```

**Streaming with Suspense:**
- Render boundaries with Suspense — server suspends rendering until data loads
- Client receives HTML chunks as data resolves, avoiding waterfall delays
- Fallback UI shows while server computes data

**Layout patterns:**
- Shared server layout wraps page + client islands
- Metadata generated server-side (`generateMetadata` async)

### Client Component Boundaries

**`'use client'` directive placement:**
- Put at the leaf (smallest interactive component), not root
- Leaf client component → can still render server children via props (composition)
- Root-level `'use client'` forces entire app to client-side render (defeats RSC purpose)

**Minimizing client bundle:**
```javascript
// Bad: entire form logic on client
'use client'
export default function PostForm() {
  const [post, setPost] = useState(null)
  const post = fetch('/api/posts/1').then(r => r.json()) // waterfall
  return ...
}

// Good: server fetches, client handles interactivity only
export default async function PostForm({ id }) {
  const post = await db.post.findUnique({ where: { id } })
  return <EditForm initialPost={post} /> // client component
}
```

### Common Mistakes

1. **Importing client-only libraries in server components:**
   - `zustand`, `react-query`, `axios` are client libraries
   - Server context: use `fetch` or native DB drivers instead
   - Error: "Cannot find module 'zustand'" at build time

2. **Using hooks in server components:**
   - `useState`, `useEffect`, `useContext` are client-only
   - Wrap in `'use client'` or move to client child component
   - Error: "React Hook 'useState' is called in a Server Component"

3. **Passing non-serializable props:**
   - Server can pass only serializable data to client (JSON-safe)
   - Dates, functions, Map/Set are NOT serializable
   - Solution: JSON.stringify date before passing, or compute on client
   - Error: "Tried to serialize object with Date constructor"

4. **Assuming server secrets are hidden:**
   - Any code in a server component is NOT exposed
   - Environment variables read server-side stay server-side
   - But exported function names and string literals ARE included in bundle if exported

### Coexistence with Inertia

**RSC is Next.js; Inertia is Laravel — they don't mix architecturally.**

- **RSC stack:** Next.js (App Router) + React Server Components on server
- **Inertia stack:** Laravel + Inertia SSR server-side (not RSC)

**If project has both (rare):**
- Keep them in separate parts of the monorepo (separate domains, separate deploys)
- RSC handles marketing/public (Next.js), Inertia handles SaaS/app (Laravel)
- OR migrate one to the other (Inertia → Next.js RSC is cleaner long-term)

---

## Section 2: Inertia.js Deep Patterns

Inertia.js enables Laravel to render React/Vue frontends as SPA-like experiences without an API. Props flow server → client; responses are JSON by default, HTML on initial visit.

### Shared Data (Props Available Everywhere)

**HandleInertiaRequests middleware** (app/Http/Middleware/HandleInertiaRequests.php):
```php
public function share(Request $request): array
{
  return [
    'auth' => auth()->user(),
    'flash' => session()->get('flash'),
    'errors' => session()->get('errors'),
  ];
}
```

**Access in any component via `usePage()`:**
```javascript
import { usePage } from '@inertiajs/react'

export default function Header() {
  const { auth } = usePage().props
  return <span>{auth.user?.name}</span>
}
```

**Avoid prop drilling:** Shared data is a singleton props layer — don't pass `auth` through 5 levels of components. Use `usePage()` at any depth.

### Partial Reloads (Performance Optimization)

**`only:` — fetch only specified props:**
```php
// Server method merges only requested props with page cache
return Inertia::render('Dashboard', [
  'stats' => Stats::get(),
  'recent_activity' => Activity::latest()->take(10)->get(),
  'all_users' => User::all(), // expensive, not used on activity updates
])

// Client only asks for activity refresh — `visit` is not a bare importable
// function; it's a method on the `router` singleton exported by @inertiajs/react
// (confirmed against node_modules/@inertiajs/core/types/index.d.ts: only `router`,
// `config`, `progress`, etc. are exported — no standalone `visit`).
import { router } from '@inertiajs/react'
router.visit('/dashboard', { only: ['recent_activity'] })
```

**`Inertia::optional()` — partial-reload-only prop (Inertia v2 rename of the old `lazy` prop):**
```php
Inertia::render('Dashboard', [
  'stats' => Stats::get(),
  'heavy_data' => Inertia::optional(fn() => ExpensiveQuery::get()), // only evaluated on a partial reload that requests it
])
```

**When to use:**
- `only:` for frequent, targeted reloads (filter changes, pagination)
- `Inertia::optional()` for secondary panels or tabs (load only when the client explicitly asks for that prop via a partial reload)

### Form Helpers (useForm Hook)

**Standard form flow:**
```javascript
import { useForm } from '@inertiajs/react'
import InputError from '@/Components/InputError'
import LoadingButton from '@/Components/LoadingButton'   // adjust to the project's component paths

export default function CreatePost() {
  const { data, setData, post, processing, errors } = useForm({
    title: '',
    content: '',
  })

  return (
    <form onSubmit={(e) => {
      e.preventDefault()
      post('/posts', { onSuccess: () => alert('Saved!') })
    }}>
      <input value={data.title} onChange={e => setData('title', e.target.value)} />
      <InputError message={errors.title} />
      <LoadingButton loading={processing}>Save</LoadingButton>
    </form>
  )
}
```

**Progress indicator + error handling:**
```javascript
const { post, progress } = useForm(data)

return (
  <div>
    {progress && <ProgressBar value={progress.percentage} />}
    <button disabled={progress}>Submit</button>
  </div>
)
```

**`preserveState` — keep form data on navigation (back button):**
```javascript
post('/posts', { preserveState: true })
```

### Persistent Layouts (Nested Layouts)

**Layout component (shared header/sidebar):**
```javascript
export default function Layout({ children }) {
  return (
    <div>
      <Header />
      <div className="layout">{children}</div>
      <Footer />
    </div>
  )
}
```

**Page specifies layout:**
```javascript
import Layout from '@/Layouts/Layout'

function Dashboard() { ... }

Dashboard.layout = (page) => <Layout children={page} />

export default Dashboard
```

**Nested layouts (multi-level):**
```javascript
DashboardView.layout = (page) =>
  <AppLayout children={
    <AdminLayout children={page} />
  } />
```

**Benefit:** Layout persists across page navigations (no flicker), state in layout survives page changes.

### Deferred Props and Prefetching

**Deferred props (server-side async boundaries — Inertia v2 `Inertia::defer()`, not `Inertia::lazy()`):**
```php
return Inertia::render('ProductShow', [
  'product' => Product::find($id),
  'reviews' => Inertia::defer(fn() => $product->reviews()->paginate()),
  'recommendations' => Inertia::defer(fn() => $product->recommendations()),
])
```

**Prefetch on hover/focus (anticipate navigation):**
```javascript
import { Link } from '@inertiajs/react'

<Link href="/products/123" prefetch>View Product</Link>
// Fetches page in background on hover
```

### Merging Props (Infinite Scroll / Paginated Feeds)

**`Inertia::merge()` / `Inertia::deepMerge()` — the Inertia v2 primitive for accumulating list data
across partial reloads** (verified against `inertiajs/inertia-laravel`'s installed source:
`ResponseFactory::merge($value): MergeProp` and `::deepMerge($value): MergeProp` both exist; `MergeProp`
implements the `Mergeable` interface with `matchOn()`, `append()`, `prepend()`):

```php
return Inertia::render('Feed', [
  'posts' => Inertia::merge(fn () => Post::latest()->paginate(20)->items())->matchOn('id'),
])
```

- `merge()` shallow-merges the incoming value into the client's existing prop; `deepMerge()` recurses
  into nested arrays/objects (`deepMerge()` sets a `deepMerge` flag and still implies `merge()`).
- `->matchOn('id')` (or a dotted path for nested structures) de-dupes by a matching key instead of
  blindly concatenating — needed whenever a "load more" page can overlap already-loaded rows.
- `->append()` (default) adds new items at the end — the infinite-scroll "load more" case;
  `->prepend()` adds at the start — a live feed where newest items arrive at the top.
- `@inertiajs/react`'s built-in `<InfiniteScroll>` component (confirmed present in the installed
  `@inertiajs/react` v2 package) or a manual `router.reload({ only: ['posts'] })` on scroll-intersection
  both trigger the merge on the client.

**Caveat — merging applies ONLY on a partial reload, never on a full page load.** Verified directly in
the installed `@inertiajs/core` client (`mergeProps()`): incoming props are merged only when
`isPartial()` is true (a visit with a non-empty `only`, `except`, or `reset`) AND the response is for
the same component as the page currently on screen; otherwise the prop is replaced outright, exactly
like any non-merge prop. A fresh full-page visit (initial load, hard refresh, or any `router.visit()`
without `only`/`except`/`reset`) always REPLACES the merge prop with the server's value — it does not
merge on top of stale client state. Don't rely on `merge()` to accumulate anything across a full
navigation; seed the first page's worth of data in the initial render instead.

**Resetting an accumulated list (filters changed — "start over"):** pass `reset` naming the prop on the
reload that should discard what the client has accumulated and start fresh, e.g.
`router.reload({ data: { filter: 'archived' }, only: ['posts'], reset: ['posts'] })`. This is the
mechanism for "user changed a filter/sort on an infinite-scroll list — the old pages are no longer
valid, refetch page 1 as a full replacement, not a merge."

### SSR Considerations

**Hydration:** Server renders initial HTML, client "hydrates" (attaches event listeners).

**Memory management:**
- Each SSR request allocates Larvel container, DB connection, cache
- Shared data (auth, flash) must be serialized fresh per request (no shared state)
- Long-running SSR processes leak memory; restart every N requests

**Testing SSR:**
- Disable SSR for component tests: `config(['inertia.ssr.enabled' => false])` (or set
  `INERTIA_SSR_ENABLED=false` in the test env) — this is the real toggle, read by
  `inertiajs/inertia-laravel`'s `config/inertia.php`. There is no `InertiaMiddleware`
  class in the package (the middleware Laravel apps extend is `Inertia\Middleware`,
  imported as `use Inertia\Middleware;`), and it has no `$deferred` static property —
  don't reach for that symbol.
- or test via HTTP integration test with SSR enabled

---

## Section 3: Real-Time / WebSocket Patterns

Real-time features (notifications, collaborative editing, live dashboards) require server-to-client push. Laravel Broadcasting provides abstraction over Pusher/Reverb/Ably.

### Laravel Broadcasting Setup

**Broadcaster types:**
- **Pusher:** Hosted service, easiest for SaaS (free tier 100 concurrent connections)
- **Reverb:** First-party Laravel WebSocket server (free, self-hosted)
- **Ably:** Hosted realtime platform with better pricing at scale

**Configuration (.env):**
```env
BROADCAST_CONNECTION=reverb
REVERB_PORT=8080
# or BROADCAST_CONNECTION=pusher + PUSHER_APP_KEY, etc.
# Laravel 11+ renamed this from BROADCAST_DRIVER to BROADCAST_CONNECTION.
```

### Channel Types & When to Use

**Public channels** (`public-posts`)
- Anyone can subscribe
- Post published: `PostPublished` event broadcasts to all subscribers
- Use: announcement feeds, live sports scores, public activity feeds

**Private channels** (`private-chat-{user_id}`)
- Authorized subscribers only
- Server authorizes via `broadcastingAs()` or `authorizationCallback`
- Use: personal notifications, direct messages, sensitive activity

**Presence channels** (`presence-meeting-{meeting_id}`)
- Track who's online (presence list)
- Member joins: broadcast to channel
- Member leaves: auto-remove from presence
- Use: collaborative editing (show cursor positions), meeting participant lists, "who's viewing" indicators

### Frontend Subscription Patterns

**Echo (Laravel Broadcasting client library):**
```javascript
import Echo from 'laravel-echo'

window.Echo = new Echo({
  broadcaster: 'reverb', // or 'pusher'
  key: import.meta.env.VITE_PUSHER_APP_KEY,
})
```

**Subscribe to public channel:**
```javascript
Echo.channel('posts')
  .listen('PostPublished', (e) => {
    console.log('New post:', e.post)
  })
  .listen('PostUpdated', (e) => {
    console.log('Post updated:', e.post)
  })
```

**Subscribe to private channel:**
```javascript
Echo.private(`chat-${recipientId}`)
  .listen('MessageSent', (e) => {
    setMessages(msgs => [...msgs, e.message])
  })
```

**Presence channel + hooks pattern:**
```javascript
function usePresence(channelName) {
  const [members, setMembers] = useState([])

  useEffect(() => {
    const presence = Echo.join(`presence-${channelName}`)
      .here((users) => setMembers(users))
      .joining((user) => setMembers(m => [...m, user]))
      .leaving((user) => setMembers(m => m.filter(u => u.id !== user.id))
      .listen('UserCursorMoved', (e) => {
        setCursors(prev => ({ ...prev, [e.user.id]: e.position }))
      })

    return () => presence.unsubscribe()
  }, [])

  return { members }
}
```

### Common SaaS Use Cases

**Live notifications:**
- Event triggers broadcast → user's private channel → frontend toast appears
- Minimize latency: broadcast immediately, not batch
- Fallback: polling every 30s for clients with flaky connections

**Dashboard updates:**
- Server-side job updates metrics → broadcasts to `public-dashboard`
- Subscribers auto-update UI without refresh
- Use `only:` partial reloads to fetch updated state on broadcast

**Collaborative editing (Figma-like):**
- Client types: sends change to server
- Server broadcasts to presence channel with user ID + change
- Clients apply changes; show cursor positions
- Conflict resolution: last-write-wins or operational transform (advanced)

**Activity feeds:**
- User action (like, comment, follow) triggers broadcast
- Feed subscribers receive event, append to feed
- Pagination: server maintains feed; broadcast signals to refresh

### Performance & Reliability

**Connection limits:**
- Pusher free tier: 100 concurrent connections
- Reverb: scales to thousands per server
- Plan for subscriber count × broadcast frequency (e.g., 1000 users, 10 broadcasts/sec = test at load)

**Reconnection strategy:**
- Echo auto-reconnects on disconnect
- Heartbeat every 30s (configurable)
- Exponential backoff: 1s, 2s, 4s, 8s, ... up to 60s

**Fallback to polling:**
```javascript
// If broadcast fails (no WebSocket), poll every 30s
const fallbackInterval = setInterval(() => {
  fetch('/api/notifications?since=' + lastCheck)
    .then(r => r.json())
    .then(data => setNotifications(data))
}, 30_000)
```

### Testing Real-Time Features

**Fake broadcast events in tests (there is no `Broadcast::fake()` / `Broadcast::assertBroadcasted()` — broadcastable events are asserted with `Event::fake()`):**
```php
// Disable real event dispatch (and therefore real broadcasting) in test
Event::fake([PostPublished::class]);

// Trigger event, assert it was dispatched (PostPublished implements ShouldBroadcast)
$this->post('/posts', ['title' => 'Test']);
Event::assertDispatched(PostPublished::class, function ($event) {
  return $event->post->title === 'Test';
});
```

**Test channel authorization (test the `routes/channels.php` callback directly — there is no `Broadcast::shouldReceiveOn()`):**
```php
// routes/channels.php
// Broadcast::channel('chat.{id}', fn ($user, $id) => $user->id === (int) $id);

$this->actingAs($user)
  ->post('/broadcasting/auth', ['channel_name' => 'private-chat.1'])
  ->assertOk(); // 403 if the callback returns false
```

**Integration test with real WebSocket (slow, avoid unless needed):**
```php
// Start Reverb in background
// Connect WebSocket client via Ratchet/Centrifuge
// Send event, assert received
// Cleanup WebSocket
```

---

## Summary Table: When to Use Each Pattern

| Pattern | Best For | Avoid If |
|---------|----------|----------|
| **RSC** | SEO content, sensitive data, large deps | Heavy interactivity, lots of state |
| **Inertia** | Monolithic SaaS, Laravel → React bridge | Separate frontend repo, heavy real-time |
| **Partial reloads** | Filtering, pagination, targeted updates | Full-page semantic changes |
| **`Inertia::defer()` / `Inertia::optional()`** | Secondary panels, deferred load | Critical-path data (load sync) |
| **`Inertia::merge()` / `deepMerge()`** | Infinite-scroll / paginated feeds, live-prepended items | Data that must land intact on a full (non-partial) page load |
| **Public channels** | Public feeds, announcements | Sensitive data (use private) |
| **Presence channels** | Collaborative editing, "who's online" | Simple one-way broadcasts (use public) |
| **WebSocket fallback** | Reliability on mobile, flaky networks | Every deployment (polling overhead) |

