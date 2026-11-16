/// Installed at document start, before a desktop avatar runtime captures RAF.
/// This gates browser RAF only; it does not replace Flutter/native schedulers.
String avatarFrameGateScript({
  required bool active,
  required bool reducedMotion,
}) =>
    '''
(() => {
  if (window.Talk2UFrameGate) return;
  const request = window.requestAnimationFrame.bind(window);
  const cancel = window.cancelAnimationFrame.bind(window);
  const pending = new Map();
  let nextId = 1, scheduled = null, active = $active, reduced = $reducedMotion;
  let initialFrame = true;
  function schedule() {
    if (scheduled !== null || !active || (reduced && !initialFrame) || !pending.size) return;
    scheduled = request(time => {
      scheduled = null;
      initialFrame = false;
      const batch = Array.from(pending.entries());
      for (const [id, callback] of batch) {
        if (!pending.delete(id)) continue;
        try { callback(time); } catch (error) { console.error(error); }
      }
      schedule();
    });
  }
  window.requestAnimationFrame = callback => {
    const id = nextId++;
    pending.set(id, callback);
    schedule();
    return id;
  };
  window.cancelAnimationFrame = id => { pending.delete(id); };
  window.Talk2UFrameGate = {
    setPolicy(policy) {
      active = policy.active;
      reduced = policy.reducedMotion;
      if (scheduled !== null) { cancel(scheduled); scheduled = null; }
      schedule();
    },
    invalidate() { initialFrame = true; schedule(); }
  };
})();
''';
