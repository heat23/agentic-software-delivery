# Artifact Schemas & Templates

_Last reviewed: 2026-08-02 (single-source-of-truth fix: SEO_AUDIT dimensions line said "4 Standard" — the skill's own Entry Point + subagent_count both say Standard = 5 dims (1-4 and 7); corrected. Prior: 2026-07-05 ecosystem review sweep)._

Referenced by `_v-core.md`. Load this file when creating or validating artifacts.

## PLAN_SCHEMA
type: document_template

Core fields (always required):

### Summary
[What is changing and why]

### Scope
- in:
- out:

### Files
- modify:
- create:

### Tests Required
- [ ] [test case]

### Acceptance Criteria
- [ ] behavior is testable
- [ ] output artifact is defined
- [ ] rollout and rollback are defined

### Rollback Notes
- application rollback:
- data rollback:

---

Conditional growth block, only when `_v-growth.md` trigger categories match:

### Target Metric
[Primary metric this work should move]

### Instrumentation
- event:
- property:
- success event:

### Post-Launch Readout
- review window:
- success threshold:
- next decision:

---

Conditional onboarding / first-run UX block:

### First Success Path
first_success_path: [non-empty path to first user value]
success_event: [event proving first success]

---

Conditional new-product planning block, only when the plan scope is a new product or product-from-scratch:

### New Product Viability
- acquisition_channel_assumptions:
- activation_milestone:
- retention_loop:
- monetization_trigger:
- support_or_feedback_intake_path:

## PLAN
type: artifact_spec
artifact_class: strategic
default_path: PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- summary
- scope
- files
- tests_required
- acceptance_criteria
- rollback_notes

## AUDIT_REPORT
type: artifact_spec
artifact_class: strategic
default_path: AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- audit_scope
- findings
- evidence_summary
- recommended_next_action

## REFACTOR_PLAN
type: artifact_spec
artifact_class: strategic
default_path: REFACTOR_PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- refactor_scope
- prioritized_changes
- risk_notes
- verification_plan

## IMPLEMENTATION_REPORT
type: artifact_spec
artifact_class: operational
default_path: IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md
fields:
- summary
- files_changed
- verification
- open_issues
- next_step

## BUILD_BLOCKER
type: artifact_spec
artifact_class: strategic
default_path: BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- blocked_step
- partial_progress
- files_touched
- failing_command
- recovery_hint

## PROGRESS_NOTE
type: artifact_spec
artifact_class: operational
default_path: PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md
fields:
- session_id
- current_step
- partial_outputs
- blocking_on
- timestamp

## PRE_FLIGHT_REPORT
type: artifact_spec
artifact_class: operational
default_path: PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md
fields:
- session_id
- gate_results (pass/fail per gate)
- warnings_aggregated
- blocking_failures
- timestamp

## VERIFY_DONE_REPORT
type: artifact_spec
artifact_class: operational
default_path: VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md
fields:
- session_id
- files_checked
- findings (convention violations, missing patterns)
- agent_dispatch_outcome
- timestamp

## AGENT_REVIEW
type: artifact_spec
artifact_class: operational
default_path: AGENT_REVIEW_${CLAUDE_SESSION_ID}.md
fields:
- session_id
- status (must be `completed`, `pass`, or `passed` for live gate acceptance)
- agents_dispatched
- codex_adversarial_reviewer (must prove `codex-adversarial-reviewer` ran, or `superpowers:requesting-code-review` fallback ran)
- hostile_adversarial_focus (`yes` when auth/payment/data-deletion/encryption/upload/external-input changes require it, otherwise `no`)
- dispatch_mode
- review_evidence (for example: `claude_accepted`, `codex_candidates`, `findings: N`, `superpowers:requesting-code-review`, `CODEX-*`, `SREV-*`, `No issues found`, or `Raw Findings`)
- finding_count_by_severity
- adjudication_verdicts (ACCEPT/MODIFY/REJECT per finding)
- remediation_summary
- timestamp
notes:
- degraded self-review markers such as `review_mode: self-review (degraded)`, `degradation_note`, or manual-substitute wording do not satisfy live gate validation

## POLISH_PLAN
type: artifact_spec
artifact_class: operational
default_path: POLISH_PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- mode (standalone/scoped)
- files_audited
- delight_score (standalone only)
- fixes_applied (scoped only)
- build_check_result
- timestamp

## HANDOFF
type: artifact_spec
artifact_class: strategic
default_path: HANDOFF_${CLAUDE_SESSION_ID}.md   # LITERAL — no timestamp; the Stop-hook completion gates test this exact name via -f
fields:
- session_id
- work_completed
- work_remaining
- artifact_inventory
- test_build_status
- timestamp

## DOCS_AUDIT
type: artifact_spec
artifact_class: operational
default_path: DOCS_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- session_id
- files_audited
- gaps_found
- recommendations
- timestamp

## LAUNCH_CHECKLIST
type: artifact_spec
artifact_class: strategic
default_path: LAUNCH_CHECKLIST_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- session_id
- env_checks
- dependency_checks
- rollback_plan
- go_nogo_verdict
- timestamp

## IMPLEMENTATION_PROMPTS
type: artifact_spec
artifact_class: strategic
default_path: IMPLEMENTATION_PROMPTS_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- source_audit
- session_count
- total_estimated_hours
- sessions (name, findings, file_targets, hour_estimate)
- cross_session_dependencies

## SALES_PRICING_AUDIT
type: artifact_spec
artifact_class: strategic
default_path: SALES_PRICING_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.json
companion: SALES_PRICING_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- audit_metadata (project_name, audit_date, audit_type, total_dimensions, total_findings, by_priority, sales_pipeline_score, pricing_revenue_score, overall_score, revenue_readiness, scorecard)
- priority_actions
- findings (id, priority, confidence, dimension, track, title, description, evidence, revenue_impact, implementation, effort_hours, growth_hook)

## ANALYTICS_AUDIT
type: artifact_spec
artifact_class: strategic
default_path: ANALYTICS_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.json
companion: ANALYTICS_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- audit_metadata (project_name, audit_date, audit_type, total_dimensions, total_findings, by_priority, instrumentation_score, measurement_score, presentation_score, overall_score, analytics_health, scorecard)
- priority_actions
- findings (id, priority, confidence, dimension, layer, title, description, evidence, data_impact, implementation, effort_hours, growth_hook)

## MESSAGING_AUDIT
type: artifact_spec
artifact_class: strategic
default_path: MESSAGING_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.json
companion: MESSAGING_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.md
fields:
- audit_metadata (project_name, audit_date, audit_type, total_dimensions, total_findings, by_priority, acquisition_messaging_score, conversion_messaging_score, retention_messaging_score, integrity_score, overall_score, messaging_health, scorecard)
- priority_actions
- findings (id, priority, confidence, dimension, layer, title, description, evidence, surfaces_affected, messaging_fix, conversion_impact, implementation, effort_hours, growth_hook)

## SEO_AUDIT
type: artifact_spec
artifact_class: strategic
default_path: SEO_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.json
companion: SEO_AUDIT_[timestamp]_${CLAUDE_SESSION_ID}.md (standalone mode only — executive summary, priority actions, content calendar, next steps)
emitter: v-audit-seo
consumers: v-content-ops (calendar → CONTENT_BRIEF generation), v-content-create (topic selection), /v routing (SEO_AUDIT filename reference)
fields:
- audit_metadata (project_name, audit_date, depth: quick|standard|thorough, integration_mode, seo_health_score)
- dimensions (per-dimension scores 0-100 with findings and recommendations — 9 Thorough / 5 Standard (dims 1-4 and 7) / 2 Quick)
- findings (id, priority, confidence, dimension, title, description, evidence, implementation, effort_hours)
- content_calendar (prioritized article/topic list — the hand-off consumed by /v-content-ops)
- priority_actions

<!-- CONTENT_SEO_PLAN retired 2026-07-05: registered here + cited by /v routing and v-content-create's
     accepts: for over a year with ZERO producers (no skill ever wrote that filename). The real
     SEO-strategy chain is: /v-audit-seo → SEO_AUDIT_*.json/.md → /v-content-ops → CONTENT_BRIEF_*.md
     → /v-content-create. Do not re-add without a producer. -->

## CONTENT_BRIEF
type: artifact_spec
artifact_class: strategic
default_path: CONTENT_BRIEF_[topic-slug]_${CLAUDE_SESSION_ID}.md
fields:
- target_keyword (primary + secondary keywords with volume/difficulty estimates)
- search_intent (informational, commercial, mixed)
- target_audience
- content_angle (unique perspective or data advantage)
- outline (H1/H2/H3 structure with keyword clusters per section)
- competitors_to_beat (URLs with coverage gaps identified)
- word_count_target
- internal_links (links TO and links FROM)
- visual_content_plan (hero + section visuals + interactive + social image)

## CI_FIX_SUMMARY
type: artifact_spec
artifact_class: operational
default_path: CI_FIX_SUMMARY_${CLAUDE_SESSION_ID}.md
emitter: v-ci-fix
emitted_when: success path (CI turned green within 3 push-watch cycles)
fields:
- branch_name
- ci_run_id
- failure_class
- files_changed
- push_watch_cycles_used
- conclusion
notes: |
  Lets Stop hooks distinguish a completed v-ci-fix run from one that crashed
  mid-flight. Companion failure-path artifact is CI_BLOCKER_*.

## CI_BLOCKER
type: artifact_spec
artifact_class: operational
default_path: CI_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md
emitter: v-ci-fix
emitted_when: failure path (3 push-watch cycles exhausted)
fields:
- branch_name
- ci_run_id
- attempts
- current_failure
- hypothesis
notes: |
  Companion success-path artifact is CI_FIX_SUMMARY_*.

