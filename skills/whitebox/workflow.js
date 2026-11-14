export const meta = {
  name: 'whitebox',
  description: 'Turn a split markdown spec into one tree with haiku agents: outline groups, verify, merge, describe, reshape wide branches',
  phases: [
    { title: 'Outline', detail: 'one haiku chain per group, windows in order', model: 'haiku' },
    { title: 'Verify', detail: 'check-all, redo failing windows', model: 'haiku' },
    { title: 'Merge', detail: 'one haiku agent mounts group outlines into one tree', model: 'haiku' },
    { title: 'Describe', detail: 'one haiku agent per group writes branch descriptions', model: 'haiku' },
    { title: 'Reshape', detail: 'regroup branches wider than 9, repeat until none', model: 'haiku' },
  ],
}
// args = output of:  node <cli> groups-args --work <W>   ->  {work, cli, groups:[{g, windows}]}
const WORK = args.work
const CLI = args.cli
const GROUPS = args.groups
const run = c => `node ${CLI} ${c} --work ${WORK}`
const H = { model: 'haiku' }
const TAIL = 'Read its ENTIRE output and carry out the TASK it describes exactly. Reply "done" when its final check prints OK.'

const winPrompt = (g, w) => `You work in the current project directory. First run \`${run(`check ${g} ${w}`)}\` with Bash; if it prints OK the window is already finished: reply "done" and stop. Otherwise run \`${run(`window ${g} ${w}`)}\` with Bash. ${TAIL}`
async function doWindow(g, w) {
  for (let t = 0; t < 2; t++) {
    const r = await agent(winPrompt(g, w), { ...H, phase: 'Outline', label: `g${g} w${w}` })
    if (r) return true
  }
  return false
}

phase('Outline')
await pipeline(GROUPS, async grp => {
  for (let w = 1; w <= grp.windows; w++) await doWindow(grp.g, w)
  return grp.g
})

phase('Verify')
const FAIL = { type: 'object', properties: { failing: { type: 'array', items: { type: 'object', properties: { g: { type: 'number' }, w: { type: 'number' } }, required: ['g', 'w'] } } }, required: ['failing'] }
let failing = []
for (let round = 0; round < 3; round++) {
  const r = await agent(`Run \`${run('check-all')}\` with Bash. It prints one JSON line. Return the "failing" array from it unchanged.`, { ...H, phase: 'Verify', label: `check-all #${round + 1}`, schema: FAIL })
  failing = r ? r.failing : []
  log(`verify round ${round + 1}: ${failing.length} failing windows`)
  if (!failing.length) break
  const byG = {}
  failing.forEach(f => (byG[f.g] ??= []).push(f.w))
  await pipeline(Object.entries(byG), async ([g, ws]) => {
    for (const w of ws.sort((a, b) => a - b)) await doWindow(+g, w)
    return g
  })
}
if (failing.length) log(`WARNING: ${failing.length} windows still failing: ${JSON.stringify(failing.slice(0, 20))}`)

phase('Merge')
await agent(`You work in the current project directory. Run \`${run('merge-input')}\` with Bash. ${TAIL}`, { ...H, phase: 'Merge', label: 'merge' })

phase('Describe')
await pipeline(GROUPS, async grp => {
  await agent(`You work in the current project directory. Run \`${run(`describe-input ${grp.g}`)}\` with Bash. ${TAIL}`, { ...H, phase: 'Describe', label: `describe g${grp.g}` })
  return grp.g
})

const COUNT = { type: 'object', properties: { count: { type: 'number' } }, required: ['count'] }
let wide = null
for (let round = 1; round <= 3; round++) {
  phase('Reshape')
  const r = await agent(`Run \`${run('reshape-list')}\` with Bash. It prints one JSON line. Return its "count" field.`, { ...H, phase: 'Reshape', label: `list #${round}`, schema: COUNT })
  wide = r ? r.count : 0
  log(`reshape round ${round}: ${wide} wide branches`)
  if (!wide) break
  await pipeline(Array.from({ length: wide }, (_, i) => i + 1), async n => {
    for (let t = 0; t < 2; t++) {
      const x = await agent(`You work in the current project directory. Run \`${run(`reshape-input ${n}`)}\` with Bash. ${TAIL}`, { ...H, phase: 'Reshape', label: `r${round} b${n}` })
      if (x) return n
    }
    return null
  })
  await agent(`Run \`${run('apply-reshape')}\` with Bash and reply with its output line.`, { ...H, phase: 'Reshape', label: `apply #${round}` })
}
return { failingWindows: failing, wideBranchesLeft: wide }
