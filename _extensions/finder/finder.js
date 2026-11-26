// Client-side filtering for finder pages built by finder.lua.
//
// Single-select groups: a tile matches when it lists the selected option.
// Multi-select groups:  a tile matches when it lists *all* selected options.
// Groups without a selection do not restrict anything.
// Non-matching tiles are greyed out, not hidden.
(function () {
  function initFinder(root) {
    const form = root.querySelector(".finder-filters");
    const count = root.querySelector(".finder-count");
    const groups = Array.from(form.querySelectorAll("fieldset[data-key]"));
    const tiles = Array.from(root.querySelectorAll(".finder-tile")).map((el) => ({
      el,
      filter: JSON.parse(el.dataset.filter || "{}"),
    }));

    function update() {
      const selection = groups.map((g) => ({
        key: g.dataset.key,
        multi: g.dataset.type === "multi",
        values: Array.from(g.querySelectorAll("input:checked")).map((i) => i.value),
      }));

      let matches = 0;
      tiles.forEach(({ el, filter }) => {
        const ok = selection.every(({ key, multi, values }) => {
          if (values.length === 0) return true;
          const allowed = filter[key] || [];
          return multi
            ? values.every((v) => allowed.includes(v))
            : values.some((v) => allowed.includes(v));
        });
        el.classList.toggle("finder-nomatch", !ok);
        if (ok) matches++;
      });

      if (count) {
        count.textContent =
          matches === tiles.length
            ? `Showing all ${tiles.length} options`
            : `${matches} of ${tiles.length} options match your requirements`;
      }
    }

    // Give every tile the height of the tallest tile with its description
    // closed, so opening one tile only grows that tile.
    function equalizeHeights() {
      const opened = Array.from(root.querySelectorAll(".finder-tile details[open]"));
      opened.forEach((d) => (d.open = false));
      tiles.forEach(({ el }) => (el.style.minHeight = ""));
      const max = Math.max(...tiles.map(({ el }) => el.offsetHeight));
      tiles.forEach(({ el }) => (el.style.minHeight = `${max}px`));
      opened.forEach((d) => (d.open = true));
    }

    equalizeHeights();
    window.addEventListener("load", equalizeHeights);
    window.addEventListener("resize", equalizeHeights);
    if (document.fonts) document.fonts.ready.then(equalizeHeights);

    form.addEventListener("change", update);
    // The reset event fires before the inputs are cleared.
    form.addEventListener("reset", () => setTimeout(update));
    update();
  }

  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".finder").forEach(initFinder);
  });
})();
