// grok-stt-pr.workflow.mjs — one PR of the FluidVoice Grok streaming STT plan.
// Implementer: grok-4.6 (high). Dual review gates: Codex gpt-5.6-sol (xhigh)
// and Claude Code opus-5 (xhigh). Loop until BOTH approve (no blocking/major),
// max 6 rounds then ask the operator.
//
// Durable copy: ~/.flowition/workflows/ai-fluidvoice/grok-stt-pr.workflow.mjs
// (copy this file there before the first run; never edit a file that has a
// resumable run — iterate as grok-stt-pr-r2.workflow.mjs).
//
// Run:
//   node --check ~/.flowition/workflows/ai-fluidvoice/grok-stt-pr.workflow.mjs
//   flowition doctor
//   flowition run ~/.flowition/workflows/ai-fluidvoice/grok-stt-pr.workflow.mjs \
//     --cwd "$WT" --detach --concurrency 4 --args-file /tmp/grok-stt-pr-args.json
//
// args JSON: { "worktree": "<abs path>", "pr": "PR1"|"PR2"|"PR3a"|"PR3b"|"PR4"|"PR5" }

import { execSync } from 'node:child_process'

export const meta = {
  name: 'fluidvoice-grok-stt-pr',
  description:
    'Implement one Grok STT PR with grok-4.6, then loop Codex+Claude review until both pass',
  phases: [
    { title: 'Implement' },
    { title: 'Review loop' },
    { title: 'Compile/test gate' },
  ],
  argsSchema: {
    type: 'object',
    properties: {
      worktree: { type: 'string' },
      pr: { type: 'string', enum: ['PR1', 'PR2', 'PR3a', 'PR3b', 'PR4', 'PR5'] },
    },
    required: ['worktree', 'pr'],
    additionalProperties: false,
  },
}

const GROK = { adapter: 'grok', model: 'grok-4.6', effort: 'high' }
const CODEX = { adapter: 'codex', model: 'gpt-5.6-sol', effort: 'xhigh' }
const CLAUDE = { adapter: 'claude', model: 'claude-opus-5', effort: 'xhigh' }

const MAX_ROUNDS = 6
const STALL_IMPL = 50 * 60_000
const STALL_REVIEW = 40 * 60_000

const PR_TITLES = {
  PR1: 'Add Grok Speech (xAI) engine catalog entry (no network)',
  PR2: 'Add Grok STT credential resolver (Keychain API key + read-only CLI store)',
  PR3a: 'Branch ASRService onto a streaming session protocol (fake Grok session)',
  PR3b: 'Connect Grok STT WebSocket (API-key first; CLI-socket gated on L4)',
  PR4: 'Use xAI REST STT for meeting/file audio when Grok Speech is selected',
  PR5: 'Harden Grok STT: redaction, labels, remaining test matrix',
}

const IMPL_RESULT = {
  type: 'object',
  properties: {
    completed: { type: 'boolean' },
    summary: { type: 'string' },
    commits: { type: 'array', items: { type: 'string' } },
    testsAdded: { type: 'array', items: { type: 'string' } },
    deviations: { type: 'array', items: { type: 'string' } },
    probes: { type: 'array', items: { type: 'string' } },
    blockedOn: { type: ['string', 'null'] },
  },
  required: [
    'completed',
    'summary',
    'commits',
    'testsAdded',
    'deviations',
    'probes',
    'blockedOn',
  ],
  additionalProperties: false,
}

const REVIEW = {
  type: 'object',
  properties: {
    approve: { type: 'boolean' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['blocking', 'major', 'minor'] },
          title: { type: 'string' },
          detail: { type: 'string' },
          file: { type: ['string', 'null'] },
          suggestedFix: { type: 'string' },
        },
        required: ['severity', 'title', 'detail', 'file', 'suggestedFix'],
        additionalProperties: false,
      },
    },
    overbuiltCode: { type: 'array', items: { type: 'string' } },
    specViolations: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['approve', 'items', 'overbuiltCode', 'specViolations', 'summary'],
  additionalProperties: false,
}

const FIX_RESULT = {
  type: 'object',
  properties: {
    applied: { type: 'array', items: { type: 'string' } },
    rejected: {
      type: 'array',
      items: {
        type: 'object',
        properties: { finding: { type: 'string' }, why: { type: 'string' } },
        required: ['finding', 'why'],
        additionalProperties: false,
      },
    },
    commits: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['applied', 'rejected', 'commits', 'summary'],
  additionalProperties: false,
}

const GATE = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    summary: { type: 'string' },
    tail: { type: ['string', 'null'] },
  },
  required: ['ok', 'summary', 'tail'],
  additionalProperties: false,
}

function common(wt, pr) {
  return (
    'You are working on FluidVoice Grok streaming STT in the git worktree at ' +
    wt +
    ' on branch feat/grok-streaming-stt. PR scope: ' +
    pr +
    ' — ' +
    PR_TITLES[pr] +
    '.\n\n' +
    'Read these FIRST, in order, and treat them as the contract. Do not re-open locked decisions:\n' +
    '1. ' + wt + '/docs/grok-stt/CONVERGED-ARCHITECTURE.md\n' +
    '2. ' + wt + '/docs/grok-stt/GROK-STT-DESIGN.md (implement this PR section only)\n' +
    'Apply CONVERGED-ARCHITECTURE "Mandatory amendments" even if a sentence in GROK-STT-DESIGN still says otherwise.\n\n' +
    'Hard rules:\n' +
    '- Opt-in only. Never default. Never onboarding. Never auto-enable.\n' +
    '- New code under Sources/Fluid/Services/GrokSTT/ plus StreamingTranscriptionSession.swift. Touch ASRService / ContentView / SettingsStore only at documented branch points. No drive-by refactors of the local ASR path.\n' +
    '- Never write ~/.grok/auth.json. Never decode refresh_token. Spawn `grok sessions list -n 1` only (never kill, never bare "grok").\n' +
    '- STT keys != LLM keys. Do not reuse Keychain com.fluidvoice.provider-api-keys / "xai" or xai-grok-subscription.\n' +
    '- modelsExistOnDisk() = false. supportsStreaming = true. runStreamingLoop must never run for this provider.\n' +
    '- Pre-audio.done socket drop with partials = retryable; do not insert.\n' +
    '- Two explicit STT auth modes (Grok CLI session vs API key). Errors must not switch billing modes.\n' +
    '- One catch-up owner: pump while isRunning. After stop getAll/clear, finish() never reads audioBuffer; hand entire capturedPCM via handoffUnsentPCM.\n' +
    '- ASRService.start() non-blocking. Provider/session off MainActor. Overlay must not hide before stop on default dictation (ContentView.swift:2108-2125).\n' +
    '- Do not branch from or merge .cowork/pr-820-src. PR 820 is LLM OAuth, not STT.\n' +
    '- Do not push. Do not open a GitHub PR. Do not mutate files outside this worktree.\n' +
    '- Add new tests to the FluidDictationIntegrationTests Xcode target (not a synchronized folder).\n' +
    '- If you report progress, you may run: flowition post "<short status>" (FLOWITION_RUN_ID is set).\n'
  )
}

function reviewRules() {
  return (
    'Review rules:\n' +
    '- READ-ONLY. Do not modify, create, or delete files. git/grep/read and running existing tests are fine. Do not install packages.\n' +
    '- approve=true ONLY if you would co-sign this PR as correct vs the contract, complete for this PR scope, and free of blocking/major issues. Minors do not block approve.\n' +
    '- If any blocking or major item exists, approve MUST be false.\n' +
    '- Report only concrete, evidenced findings. Cite files. Do not re-litigate locked product decisions.\n' +
    '- blocking = wrong behavior, contract violation, security/credential bug, local-engine regression, default/onboarding enable, auth.json write, MainActor isolation leak, insert of pre-audio.done partials, Activate enabled before PR3b, modelsExistOnDisk true, runStreamingLoop for Grok.\n' +
    '- major = real product bug, missing required test, missing exhaustive SpeechModel arm, catch-up/handoff bug, overlay hide-before-stop.\n' +
    '- minor = polish. overbuiltCode = code/tests that overshoot the spec (recommend deletion).\n' +
    '- specViolations = any place the code contradicts CONVERGED-ARCHITECTURE or this PR section of GROK-STT-DESIGN.\n' +
    '- Do not re-raise items the implementer adequately fixed with evidence in priorContext.\n'
  )
}

function gateCmd() {
  return (
    "xcodebuild test -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' " +
    'CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO'
  )
}

export default async function ({ agent, parallel, phase, log, step, ask, args }) {
  const wt = args.worktree
  const pr = args.pr
  const prefix = pr.toLowerCase() + ':'

  phase('Implement')
  const impl = await agent(
    common(wt, pr) +
      'TASK: Implement ' +
      pr +
      ' completely per GROK-STT-DESIGN.md PR Plan for that PR (files, tests U*/L*, Activate/catalog rules). ' +
      'This may be re-run after interruption: inspect `git log --oneline -20` and `git status` first and continue rather than redo.\n' +
      'Commit in logical commits, each message prefixed "' +
      prefix +
      ' ". Do NOT push.\n' +
      'Keep local engines behavior-identical. The PR must compile.\n' +
      (pr === 'PR3b'
        ? 'Before wiring the real socket, probe authorized wss://api.x.ai/v1/stt with (1) API key and (2) CLI-store token. Record L2/L4/L5/L8/L9/L10 in the commit/PR body notes (docs/grok-stt/probes-PR3b.md). If L4 fails: ship API-key WebSocket; disable CLI-socket; do NOT silently REST-on-stop. If you lack credentials, set blockedOn and stop without faking probe results.\n'
        : '') +
      'Return the structured result. blockedOn is null unless you could not finish.',
    {
      ...GROK,
      cwd: wt,
      schema: IMPL_RESULT,
      label: 'impl:' + pr,
      stallMs: STALL_IMPL,
    },
  )
  log(pr + ' implement: ' + (impl && impl.summary ? impl.summary : String(impl)).slice(0, 400))

  if (impl && impl.blockedOn) {
    const ans = await ask(
      pr + ' implementer blocked: ' + impl.blockedOn + '. Reply "continue" after unblocking, or "stop".',
    )
    if (String(ans).trim().toLowerCase() !== 'continue') {
      return { pr, stopped: true, reason: impl.blockedOn, impl }
    }
  }

  phase('Review loop')
  let priorContext = ''
  let lastFix = null
  const rounds = []
  let approved = false

  for (let round = 1; round <= MAX_ROUNDS && !approved; round++) {
    const reviewPrompt = (name) =>
      common(wt, pr) +
      'You are reviewer "' +
      name +
      '" (round ' +
      round +
      ') for ' +
      pr +
      '.\n' +
      reviewRules() +
      'Review ONLY commits whose messages start with "' +
      prefix +
      '" (git log --oneline -30, git show / git diff). ' +
      'Implementer reported: """' +
      JSON.stringify(impl).slice(0, 6000) +
      '"""\n' +
      (priorContext
        ? '\nPrior round context (do not re-raise adequately fixed points):\n' +
          priorContext.slice(0, 8000) +
          '\n'
        : '') +
      'Perform the complete review BEFORE emitting the schema. Empty items + approve=true is the correct outcome when the work is sound.'

    const [codex, claude] = await parallel([
      () =>
        agent(reviewPrompt('codex-gpt-5.6-sol-xhigh'), {
          ...CODEX,
          cwd: wt,
          schema: REVIEW,
          label: 'review:codex:' + pr + ':r' + round,
          phase: 'Review loop',
          stallMs: STALL_REVIEW,
        }),
      () =>
        agent(reviewPrompt('claude-opus-5-xhigh'), {
          ...CLAUDE,
          cwd: wt,
          schema: REVIEW,
          label: 'review:claude:' + pr + ':r' + round,
          phase: 'Review loop',
          stallMs: STALL_REVIEW,
        }),
    ])

    const actionable = (rev, reviewer) => {
      if (!rev) return [{ reviewer, severity: 'blocking', title: 'reviewer-failed', detail: reviewer + ' agent returned null', file: null, suggestedFix: 're-run review' }]
      const items = (rev.items || [])
        .filter((i) => i.severity === 'blocking' || i.severity === 'major')
        .map((i) => ({ reviewer, ...i }))
      const extra = (rev.specViolations || []).map((s) => ({
        reviewer,
        severity: 'blocking',
        title: 'spec-violation',
        detail: s,
        file: null,
        suggestedFix: 'conform to CONVERGED-ARCHITECTURE + GROK-STT-DESIGN',
      }))
      const over = (rev.overbuiltCode || []).map((s) => ({
        reviewer,
        severity: 'major',
        title: 'overbuilt',
        detail: s,
        file: null,
        suggestedFix: 'delete or shrink',
      }))
      return items.concat(extra).concat(over)
    }

    const codexAction = actionable(codex, 'codex')
    const claudeAction = actionable(claude, 'claude')
    const allAction = codexAction.concat(claudeAction)
    const minors = [codex, claude]
      .filter(Boolean)
      .flatMap((r) => (r.items || []).filter((i) => i.severity === 'minor'))

    const codexOk = !!(codex && codex.approve === true && codexAction.length === 0)
    const claudeOk = !!(claude && claude.approve === true && claudeAction.length === 0)
    rounds.push({
      round,
      codexOk,
      claudeOk,
      codexSummary: codex ? codex.summary : 'FAILED',
      claudeSummary: claude ? claude.summary : 'FAILED',
      actionable: allAction.length,
    })
    log(
      pr +
        ' round ' +
        round +
        ': codex=' +
        (codexOk ? 'PASS' : 'FAIL') +
        ' claude=' +
        (claudeOk ? 'PASS' : 'FAIL') +
        ' actionable=' +
        allAction.length,
    )

    if (codexOk && claudeOk) {
      approved = true
      if (minors.length > 0) {
        await agent(
          common(wt, pr) +
            'TASK: Do NOT change product code. Append these minor findings verbatim to docs/grok-stt/review-notes.md under heading "' +
            pr +
            ' round ' +
            round +
            '". Create the file if needed. Commit as "' +
            prefix +
            ' docs: capture residual minor review notes".\n' +
            JSON.stringify(minors, null, 2),
          { ...GROK, cwd: wt, schema: FIX_RESULT, label: 'minors:' + pr + ':r' + round },
        )
      }
      break
    }

    if (round === MAX_ROUNDS) break

    lastFix = await agent(
      common(wt, pr) +
        'TASK: Review round ' +
        round +
        ' did not pass. Both gates must pass; fix real blocking/major findings and overbuilt/spec violations. ' +
        'Commits prefixed "' +
        prefix +
        ' fix:". If a finding is factually wrong, do not change code for it — record it under rejected with evidence.\n' +
        'Do not act on minors except appending them to docs/grok-stt/review-notes.md.\n\n' +
        'Actionable findings:\n' +
        JSON.stringify(allAction, null, 2) +
        '\n\nCodex full review:\n' +
        JSON.stringify(codex, null, 2).slice(0, 8000) +
        '\n\nClaude full review:\n' +
        JSON.stringify(claude, null, 2).slice(0, 8000) +
        '\n\nRe-run this PR\'s tests after fixing. Return the structured result.',
      {
        ...GROK,
        cwd: wt,
        schema: FIX_RESULT,
        label: 'fix:' + pr + ':r' + round,
        stallMs: STALL_IMPL,
      },
    )
    priorContext =
      'Round ' +
      round +
      ' actionable:\n' +
      JSON.stringify(allAction).slice(0, 6000) +
      '\nFix disposition:\n' +
      JSON.stringify(lastFix).slice(0, 4000)
  }

  if (!approved) {
    const ans = await ask(
      pr +
        ' review loop exhausted after ' +
        MAX_ROUNDS +
        ' rounds without dual PASS. Reply "continue" to run 3 more rounds later (you will start a fresh workflow run), or "stop". Latest: ' +
        JSON.stringify(rounds[rounds.length - 1] || {}),
    )
    if (String(ans).trim().toLowerCase() !== 'continue') {
      return { pr, approved: false, rounds, impl, lastFix, stopped: true }
    }
  }

  phase('Compile/test gate')
  const gate = await step('xcode-test', { pr, wt }, () => {
    try {
      const out = execSync(gateCmd(), {
        cwd: wt,
        encoding: 'utf8',
        stdio: 'pipe',
        maxBuffer: 64 * 1024 * 1024,
        timeout: 20 * 60_000,
      })
      return { ok: true, summary: 'xcodebuild test passed', tail: out.slice(-2000) }
    } catch (e) {
      const tail = (String(e.stdout ?? '') + '\n' + String(e.stderr ?? '')).slice(-8000)
      return { ok: false, summary: 'xcodebuild test failed', tail }
    }
  })

  if (!gate.ok) {
    log('gate red — one repair round')
    await agent(
      common(wt, pr) +
        'TASK: The compile/test gate failed. Fix only what makes this command pass:\n' +
        gateCmd() +
        '\n\nTail:\n' +
        String(gate.tail || '').slice(0, 8000) +
        '\nCommits prefixed "' +
        prefix +
        ' fix:". Do not refactor. Verify the command passes before finishing.',
      { ...GROK, cwd: wt, schema: FIX_RESULT, label: 'gatefix:' + pr, stallMs: STALL_IMPL },
    )
    const gate2 = await step('xcode-test', { pr, wt, attempt: 2 }, () => {
      try {
        const out = execSync(gateCmd(), {
          cwd: wt,
          encoding: 'utf8',
          stdio: 'pipe',
          maxBuffer: 64 * 1024 * 1024,
          timeout: 20 * 60_000,
        })
        return { ok: true, summary: 'xcodebuild test passed after repair', tail: out.slice(-2000) }
      } catch (e) {
        const tail = (String(e.stdout ?? '') + '\n' + String(e.stderr ?? '')).slice(-8000)
        return { ok: false, summary: 'xcodebuild test still failing', tail }
      }
    })
    if (!gate2.ok) {
      throw new Error(pr + ' gate still red after repair:\n' + String(gate2.tail).slice(-3000))
    }
    return {
      pr,
      approved,
      rounds,
      impl,
      lastFix,
      gate: gate2,
    }
  }

  return { pr, approved, rounds, impl, lastFix, gate }
}
