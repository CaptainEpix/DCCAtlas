# Zero-result behavior

Observed searches that matched nothing produced **no @Find response at all** after 15+ seconds. There was no `Found [0]` block and no `End of @Find.` marker.

This means discovery must use a bounded collection/quiet window; it cannot wait indefinitely for an end marker when no server answers.

Also observed: SysReset `Totally Silent` mode suppresses `@Find`; `On` permits it. Silence alone is therefore not proof that a bot lacks @Find support.
