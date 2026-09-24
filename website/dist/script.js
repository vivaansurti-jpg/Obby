const LINKS = {
  download: 'https://github.com/vivaansurti-jpg/Obby/releases/latest/download/Obby.dmg',
  github: 'https://github.com/vivaansurti-jpg/Obby'
};
const dialog = document.querySelector('#availability');
document.querySelectorAll('[data-link]').forEach(link => {
  const destination = LINKS[link.dataset.link];
  if (destination) { link.href = destination; return; }
  link.addEventListener('click', event => {
    event.preventDefault();
    document.querySelector('#availability-message').textContent = link.dataset.link === 'download' ? 'The macOS download will be available here soon.' : 'The source repository link will be available here soon.';
    dialog.showModal();
  });
});
document.querySelectorAll('.close-dialog, .dismiss').forEach(button => button.addEventListener('click', () => dialog.close()));
dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });
const navigation = document.querySelector('.navigation');
const updateNavigation = () => navigation.classList.toggle('scrolled', window.scrollY > 8);
window.addEventListener('scroll', updateNavigation, { passive: true });
updateNavigation();
if ('IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) { entry.target.classList.add('visible'); observer.unobserve(entry.target); }
    });
  }, { threshold: 0.08 });
  document.querySelectorAll('.reveal').forEach(section => { section.classList.add('will-reveal'); observer.observe(section); });
}
