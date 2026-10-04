const STORAGE_KEY = "openrct2-manager-theme";

export function currentTheme() {
  const saved = localStorage.getItem(STORAGE_KEY);
  if (saved === "light" || saved === "dark") return saved;
  return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function applyTheme(theme = currentTheme()) {
  document.documentElement.dataset.theme = theme;
  document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
    button.setAttribute("aria-pressed", String(theme === "dark"));
    button.setAttribute("aria-label", theme === "dark" ? "Use light appearance" : "Use dark appearance");
  });
}

export function installThemeToggle() {
  applyTheme();
  document.addEventListener("click", (event) => {
    const button = event.target.closest("[data-theme-toggle]");
    if (!button) return;
    const theme = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    localStorage.setItem(STORAGE_KEY, theme);
    applyTheme(theme);
  });
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    if (!localStorage.getItem(STORAGE_KEY)) applyTheme();
  });
}

