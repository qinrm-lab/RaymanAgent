# Rayman Tool Policy

- task_kind: review
- prompt_key: review.initial.prompt.md
- preferred_backend: 

## Selected Tools

- `openai_docs_mcp` (capability) score=95
  evidence: official doc references
  evidence: verified model/platform notes
  reason: Official OpenAI docs are the primary source for platform-specific guidance.
- `rayman_docs_researcher` (subagent) score=55
  evidence: scoped findings
  evidence: role-specific notes
  reason: Multi-agent registry marks this role as relevant for the task shape.
- `rayman_reviewer` (subagent) score=55
  evidence: scoped findings
  evidence: role-specific notes
  reason: Multi-agent registry marks this role as relevant for the task shape.
- `local_shell` (shell) score=25
  evidence: workspace diff and local logs
  reason: Local shell remains the universal fallback and evidence collector.

## Fallback Chain

- `local_shell`
- `single_agent`

## Selected Subagents

- `rayman_reviewer`
- `rayman_docs_researcher`