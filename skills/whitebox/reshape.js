export const meta = {
  name: 'whitebox-reshape',
  description: 'whitebox: re-run only the reshape phase, regrouping branches wider than 9 into themed sub-branches with haiku agents',
  phases: [{ title: 'Reshape', detail: 'one haiku agent per wide branch, repeat until none', model: 'haiku' }],
}
// args = {work, cli}   (see workflow.js; run `apply-merge` first only if tree.paths does not exist yet)
const run = c => `node ${args.cli} ${c} --work ${args.work}`
const H = { model: 'haiku', phase: 'Reshape' }
const COUNT = { type: 'object', properties: { count: { type: 'number' } }, required: ['count'] }
let wide = null
phase('Reshape')
for (let round = 1; round <= 3; round++) {
  const r = await agent(`Run \`${run('reshape-list')}\` with Bash. It prints one JSON line. Return its "count" field.`, { ...H, label: `list #${round}`, schema: COUNT })
  wide = r ? r.count : 0
  log(`reshape round ${round}: ${wide} wide branches`)
  if (!wide) break
  await pipeline(Array.from({ length: wide }, (_, i) => i + 1), async n => {
    for (let t = 0; t < 2; t++) {
      const x = await agent(`You work in the current project directory. Run \`${run(`reshape-input ${n}`)}\` with Bash. Read its ENTIRE output and carry out the TASK it describes exactly (write the file it names, then run the check-reshape command until it prints OK). Reply "done" when it prints OK.`, { ...H, label: `r${round} b${n}` })
      if (x) return n
    }
    return null
  })
  await agent(`Run \`${run('apply-reshape')}\` with Bash and reply with its output line.`, { ...H, label: `apply #${round}` })
}
return { wideBranchesLeft: wide }
