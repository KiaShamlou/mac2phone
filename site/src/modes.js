export const modes = {
  touch: {label: 'Touch', kicker: 'NO CURSOR IN THE WAY', title: 'Your finger is the point.', description: 'Tap to click. Swipe to scroll. Hold to drag. Touch mode hides the streamed cursor and adds a small local touch indicator instead.', note: 'Two-finger scrolling stays scrolling—even at a window edge.', caption: 'DIRECT TOUCH'},
  pointer: {label: 'Pointer', kicker: 'PUT IT RIGHT THERE', title: 'A familiar point of view.', description: 'Touch a spot to position the Mac cursor directly. Move your finger to drag, with the cursor visible when your cursor preference is on.', note: 'Useful when you want to see exactly where the pointer lands.', caption: 'ABSOLUTE POINTER'},
  trackpad: {label: 'Trackpad', kicker: 'SMALL MOVES. MORE REACH.', title: 'A trackpad in your hand.', description: 'Slide your finger to move the cursor relative to its current position. Lift and reposition without moving it back across the screen.', note: 'Tap to click. Hold before moving to click-and-drag.', caption: 'RELATIVE MOVEMENT'}
};
export function nextTabIndex(key, index, count) {
  if (key === 'ArrowRight') return (index + 1) % count;
  if (key === 'ArrowLeft') return (index - 1 + count) % count;
  if (key === 'Home') return 0;
  if (key === 'End') return count - 1;
  return null;
}
export const setupCommands = 'git clone https://github.com/KiaShamlou/mac2phone.git\ncd mac2phone\nswift run mac2phone --no-speak';
