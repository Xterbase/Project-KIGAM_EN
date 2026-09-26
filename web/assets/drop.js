// web/assets/drop.js — file drop zone (#drop). Shared by index.php and dashboard.php.
// Submits #upForm as soon as a file is chosen or dropped (index.php handles it).
'use strict';
{
  const drop = document.getElementById('drop'), input = drop.querySelector('input'), form = document.getElementById('upForm');
  input.onchange = () => { if (input.files.length) { drop.querySelector('b').textContent = input.files[0].name + ' — uploading…'; form.submit(); } };
  drop.addEventListener('dragover', e => { e.preventDefault(); drop.classList.add('over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('over'));
  drop.addEventListener('drop', e => { e.preventDefault(); drop.classList.remove('over'); input.files = e.dataTransfer.files; input.onchange(); });
}
