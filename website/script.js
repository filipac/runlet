// Runlet website: reveal-on-scroll and the Copy button. No tracking, no dependencies.
(function () {
  "use strict";

  // Fade sections in once as they scroll into view (CSS skips this with reduced motion).
  var items = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    items.forEach(function (item) { observer.observe(item); });
  } else {
    items.forEach(function (item) { item.classList.add("is-visible"); });
  }

  // Copy buttons for commands (shown only where the clipboard is available).
  if (navigator.clipboard && window.isSecureContext) {
    document.querySelectorAll("button[data-copy]").forEach(function (button) {
      var source = document.getElementById(button.getAttribute("data-copy"));
      if (!source) return;
      button.hidden = false;
      button.addEventListener("click", function () {
        navigator.clipboard.writeText(source.textContent.trim()).then(function () {
          button.textContent = "Copied";
          setTimeout(function () { button.textContent = "Copy"; }, 1600);
        });
      });
    });
  }
})();
