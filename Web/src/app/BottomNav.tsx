// Нижняя навигация, срез 6: две вкладки — «Сегодня» и «Профиль». Календарь
// цикла открывается из Профиля и вкладкой не является.

import { NavLink } from 'react-router-dom'

export function BottomNav() {
  return (
    <nav className="bottom-nav" aria-label="Разделы">
      <NavLink to="/" end>
        Сегодня
      </NavLink>
      <NavLink to="/profile">Профиль</NavLink>
    </nav>
  )
}
