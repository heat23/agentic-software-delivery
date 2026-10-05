# v-error-taxonomy: Error Categories & Handling Patterns

_Last reviewed: 2026-07-06 (theme-consistency sweep B: failed-login email logging example reframed to match v-security-baseline's sanctioned structured-context form)._

Canonical error taxonomy and handling strategies. Used across skills to categorize and respond to errors consistently.

## Error Categories

### Category 1: User Error (4xx HTTP)

User provided invalid input or attempted unauthorized action.

**Examples:**
- Missing required field in form
- Email already exists during registration
- Insufficient permissions to access resource
- Invalid file format uploaded
- Page not found (typo in URL)

**HTTP Status:** 400, 401, 403, 404, 409 (conflict), 422 (validation)

**Characteristics:**
- User can fix by changing behavior (input valid data, gain permission)
- NOT an app bug
- Expected: never logged at `error` level (use `info`/`warning`), never reported to the error
  tracker, never surfaced as a stack trace or raw exception message — the response names the
  field/action the user can change

### Category 2: System Error (5xx HTTP)

Unhandled exception, unrecoverable state, or server bug.

**Examples:**
- Null pointer exception in business logic
- Database connection lost
- Disk full, out of memory
- Unhandled exception in controller
- Race condition causing corrupted state

**HTTP Status:** 500, 503

**Characteristics:**
- User cannot fix
- Indicates app bug or infrastructure failure
- Requires developer intervention

### Category 3: External Service Error

Third-party API timeout, rate limit, or failure.

**Examples:**
- Stripe API timeout during payment
- Email service returning 503
- Google OAuth temporarily unavailable
- Webhook delivery failure
- S3 upload timeout

**HTTP Status:** varies (often 502 Bad Gateway, 503 Service Unavailable, or internal handling)

**Characteristics:**
- Outside app's control
- Often transient (retry may succeed)
- May affect multiple users simultaneously

### Category 4: Business Logic Error

Valid input, but business rules prevent action. Not a bug or input error — a constraint violation.

**Examples:**
- Cannot delete last admin user
- Subscription period doesn't allow downgrade
- Budget exceeded for this request
- Duplicate task creation (idempotency check)
- State transition not allowed (e.g., publish unpublished post)

**HTTP Status:** 422 (Unprocessable Entity) or 409 (Conflict)

**Characteristics:**
- Valid input syntax, but violates domain rules
- User can fix by changing context (add another admin, upgrade tier first)
- Specific, actionable message needed
- Distinct from validation (syntax) errors

## Handling Patterns by Category

### User Error → Inline Field Errors + Toast

Provide field-level feedback immediately and a summary toast:

```typescript
// React form component
const [errors, setErrors] = useState<Record<string, string>>({});
const [toast, setToast] = useState('');

async function handleSubmit(formData: FormData) {
  try {
    const response = await api.post('/users', formData);
  } catch (error) {
    if (error.response?.status === 422) {
      // Validation errors: map to form fields
      setErrors(error.response.data.errors); // { email: 'Email already exists' }
      setToast(''); // No toast for validation (inline errors suffice)
    } else {
      throw error; // Re-throw system errors
    }
  }
}

return (
  <form onSubmit={handleSubmit}>
    <input type="email" name="email" />
    {errors.email && <span className="error">{errors.email}</span>}
    <button type="submit">Register</button>
  </form>
);
```

**Laravel FormRequest returns 422 with field errors:**

```php
public function store(StoreUserRequest $request)
{
    // If validation fails, FormRequest auto-returns 422 with errors
    // in response->errors() or as JSON: { "message": "...", "errors": { "email": ["..." }]}
    $user = User::create($request->validated());
    return response()->json(['data' => $user], 201);
}
```

**Toast for summary:** One brief message, NOT field-specific. "Please fix the highlighted fields."

### System Error → Generic Message + Sentry + Log

Never expose implementation details to users:

```typescript
// React component
async function dangerousAction() {
  try {
    const response = await api.post('/critical-action', data);
  } catch (error) {
    if (error.response?.status === 500 || !error.response) {
      // System error: generic message
      setToast('Something went wrong. Our team has been notified.');

      // Send to error tracking
      Sentry.captureException(error, {
        tags: { action: 'critical-action' },
        contexts: {
          user: { id: currentUser.id },
          data: { attempt: attemptNumber },
        },
      });
    } else {
      // Other errors (validation, business logic) handled elsewhere
      throw error;
    }
  }
}
```

**Laravel:**

```php
// app/Exceptions/Handler.php
public function render($request, Throwable $exception)
{
    // Log with context
    Log::error('Unhandled exception', [
        'exception' => $exception,
        'user_id' => auth()->id(),
        'action' => $request->path(),
        'method' => $request->method(),
    ]);

    // Report to Sentry
    Sentry::captureException($exception);

    // Return generic response to user
    if ($request->expectsJson()) {
        return response()->json([
            'message' => 'Something went wrong. Please try again.',
        ], 500);
    }

    return view('errors.500');
}
```

### External Service Error → Retry + Specific Message + Fallback

Communicate uncertainty and provide fallback:

```typescript
// React hook: retry with exponential backoff
async function callExternalAPI(url: string, maxRetries = 3) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await fetch(url).then(r => r.json());
    } catch (error) {
      if (attempt === maxRetries) {
        // Last attempt failed: show fallback
        setToast('Service temporarily unavailable. Showing cached data.');
        return getCachedData(); // Graceful fallback
      }

      // Retry with exponential backoff
      const delay = Math.pow(2, attempt) * 1000; // 2s, 4s, 8s
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
}
```

**Laravel (payment retry example):**

```php
// app/Jobs/ProcessPayment.php
class ProcessPayment implements ShouldQueue
{
    public $tries = 3;
    public $backoff = [1, 5, 10]; // Retry after 1s, 5s, 10s

    public function handle(StripeService $stripe)
    {
        try {
            $stripe->charge($this->amount, $this->customerId);
        } catch (StripeException $e) {
            if ($e->isRetryable()) {
                // Retry: framework re-queues automatically
                throw $e;
            } else {
                // Permanent failure
                Log::error('Payment failed (not retryable)', [
                    'customer_id' => $this->customerId,
                    'error' => $e->getMessage(),
                ]);

                Notification::route('mail', $this->userEmail)
                    ->notify(new PaymentFailedNotification($e->getMessage()));

                // Fallback: mark order as pending manual review
                Order::findOrFail($this->orderId)->markFailedPaymentNotified();
            }
        }
    }
}
```

### Business Logic Error → Specific Message + Suggested Action

Explain the constraint and suggest next step:

```typescript
// React: POST fails because user at tier limit
async function createProject() {
  try {
    const response = await api.post('/projects', { name: 'New Project' });
  } catch (error) {
    if (error.response?.status === 422) {
      const detail = error.response.data.message;

      if (detail === 'Project limit reached for free tier') {
        // Business logic error: actionable message with suggestion
        setToast('You've reached the project limit for your plan. Upgrade to create more.');
        navigate('/settings/billing'); // Suggested action
      } else {
        // Other validation errors
        setErrors(error.response.data.errors);
      }
    }
  }
}
```

**Laravel:**

```php
// app/Http/Controllers/ProjectController.php
public function store(StoreProjectRequest $request)
{
    $user = auth()->user();

    // Business logic check (NOT in FormRequest — this is domain logic)
    if ($user->projects_count >= $user->subscription_plan->max_projects) {
        return response()->json([
            'message' => 'You\'ve reached the project limit for your plan.',
            'suggestion' => 'Upgrade to Pro plan to create more projects.',
            'action' => '/settings/billing',
        ], 422); // 422: valid request, but business rules prevent it
    }

    $project = $user->projects()->create($request->validated());
    return response()->json(['data' => $project], 201);
}
```

## Error Response Format

### JSON API Responses

**Validation Error (422):**

```json
{
  "message": "Validation failed",
  "errors": {
    "email": ["Email is required", "Email must be unique"],
    "password": ["Password must be at least 8 characters"]
  }
}
```

**Business Logic Error (422):**

```json
{
  "message": "Cannot delete the last admin user. Promote another user to admin first.",
  "action": "/settings/team",
  "code": "LAST_ADMIN_CONSTRAINT"
}
```

**System Error (500):**

```json
{
  "message": "Something went wrong. Please try again.",
  "error_id": "ERR-20260329-abc123"
}
```

**External Service Error (503 or inline handling):**

```json
{
  "message": "Payment service temporarily unavailable. Retrying...",
  "retry_after": 5,
  "fallback": "We'll complete your order once the service recovers."
}
```

### Inertia Error Bags

For form submissions in Inertia.js:

```typescript
// Laravel returns bag after validation failure
// React component receives as prop
export default function CreatePost({ errors }: InertiaProps) {
  return (
    <form method="post" action="/posts">
      <input type="text" name="title" />
      {errors.title && <span className="error">{errors.title}</span>}

      <textarea name="content" />
      {errors.content && <span className="error">{errors.content}</span>}

      <button type="submit">Create Post</button>
    </form>
  );
}
```

### Toast Notifications

**User Error:** Show one short line (errors already on fields).

```typescript
// Bad: redundant
showToast('Email is required', 'error'); // Already showing inline

// Good: summary for non-field validation
showToast('Please fix the highlighted fields', 'error');
```

**System Error:** One-liner, no details.

```typescript
showToast('Something went wrong. Our team has been notified.', 'error');
```

**Business Logic Error:** Specific message + optional link.

```typescript
showToast('Subscription downgrade not allowed while overdue on payment. Resolve invoice first.', 'warning');
// OR with action
showToast('You\'ve reached your storage limit. Upgrade to Pro.', 'info', {
  action: 'Upgrade',
  onClick: () => navigate('/settings/billing'),
});
```

**External Service Error:** Acknowledge uncertainty.

```typescript
showToast('Payment processing is slow. We'll notify you when it completes.', 'info');
```

**Success:** Brief, positive.

```typescript
showToast('Post published!', 'success');
```

## Error Logging Standards

### Structured Context

Log errors with context, not raw exception messages:

```php
// GOOD: Structured context
Log::error('Payment processing failed', [
    'user_id' => $user->id,
    'customer_id' => $customer->stripe_id,
    'amount' => $amount,
    'currency' => $currency,
    'error_code' => $exception->getCode(),
    'error_message' => $exception->getMessage(),
    'retry_attempt' => $retryCount,
]);

// BAD: No context
Log::error($exception->getMessage());
```

### Never Log PII in Error Messages

Don't leak passwords, tokens, or personal data in logs:

```php
// GOOD
Log::error('User password reset failed', [
    'user_id' => $user->id, // Safe: identifier only
    'reason' => 'Invalid token',
]);

// BAD: Leaks the token
Log::error("Password reset failed: {$token}");

// BAD: email interpolated into the message string (unaggregatable + leaks into free text).
// The SANCTIONED form is structured context — failed-login logging with the attempted
// email in the context array is REQUIRED by v-check's v-security-baseline § Monitoring
// & Alerting, and emails are not on the CLAUDE.md never-log list:
//   Log::warning('Failed login attempt', ['email' => $email, 'ip' => $request->ip()]);
Log::error("Login failed for user {$user->email}");
```

### Error Categories in Logs

Include category to help with monitoring/alerting:

```php
Log::error('Business logic constraint violated', [
    'category' => 'business_logic', // user_error | system_error | external_service | business_logic
    'constraint' => 'LAST_ADMIN_DELETION',
    'user_id' => $user->id,
    'resource_id' => $admin->id,
]);
```

## User-Facing Error Copy Guidelines

### What, Why, What Next

Every error shown to users should answer:
1. **What happened?** Clear, plain English (never "error 422")
2. **Why?** Briefly explain the cause
3. **What to do?** Suggest the fix or next action

**Examples:**

```
GOOD:
❌ Email is already registered
   (Someone already has this email address)
   Suggestion: Try logging in or use password recovery

GOOD:
❌ You've reached your project limit (Free plan: 3 projects)
   Suggestion: Upgrade to Pro for unlimited projects → [Upgrade]

GOOD:
❌ File is too large (Max 10 MB)
   Suggestion: Compress the image or upload a smaller file

BAD:
❌ 422 Unprocessable Entity
❌ Validation failed
❌ Something went wrong
```

### Tone

- **User errors:** Matter-of-fact, not blaming. "Email is already registered" not "You used a duplicate email"
- **System errors:** Apologetic, reassuring. "Something went wrong. Our team has been notified." not "System crash"
- **Business logic:** Specific, actionable. "Subscription period doesn't allow downgrades (wait until next cycle)" not "Invalid operation"

## Error Recovery UX Patterns

### Retry Buttons

For transient errors (network, service timeout):

```typescript
const [isRetrying, setIsRetrying] = useState(false);
const [lastError, setLastError] = useState<string | null>(null);

async function handleRetry() {
  setIsRetrying(true);
  try {
    const result = await fetchData();
    setLastError(null);
  } catch (error) {
    setLastError(error.message);
  } finally {
    setIsRetrying(false);
  }
}

return (
  <>
    {lastError && (
      <div className="error-card">
        <p>{lastError}</p>
        <button onClick={handleRetry} disabled={isRetrying}>
          {isRetrying ? 'Retrying...' : 'Retry'}
        </button>
      </div>
    )}
  </>
);
```

### Fallback States

Show cached/partial data when service unavailable:

```typescript
export default function UsersList() {
  const [users, setUsers] = useState<User[]>([]);
  const [isStale, setIsStale] = useState(false);

  useEffect(() => {
    fetchUsers()
      .then(data => {
        setUsers(data);
        setIsStale(false);
      })
      .catch(() => {
        // Fall back to cached users
        const cached = localStorage.getItem('users-cache');
        if (cached) {
          setUsers(JSON.parse(cached));
          setIsStale(true); // Mark as stale
        }
      });
  }, []);

  return (
    <>
      {isStale && (
        <div className="banner info">
          Showing cached data. New changes may not be visible.
        </div>
      )}
      <UserList users={users} />
    </>
  );
}
```

### Graceful Degradation

Disable non-essential features on error:

```typescript
// Payment button unavailable if service down
<button
  onClick={handleCheckout}
  disabled={paymentServiceDown}
>
  {paymentServiceDown ? 'Payment service unavailable' : 'Checkout'}
</button>
```

## Error Categorization Decision Tree

```
Is the error a result of user input?
├─ Yes → Category 1: User Error
│  └─ Return 4xx, inline errors, field-level feedback
└─ No → Continue

Is the error a domain rule constraint (valid input, but business rules prevent it)?
├─ Yes → Category 4: Business Logic Error
│  └─ Return 422/409, specific message + action
└─ No → Continue

Did an external API/service fail?
├─ Yes → Category 3: External Service Error
│  └─ Retry + generic message + fallback
└─ No → Continue

Everything else (unhandled exception, null pointer, etc.)
└─ Category 2: System Error
   └─ Return 500, generic message, log + alert
```
