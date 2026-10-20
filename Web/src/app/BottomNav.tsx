// Нижняя навигация: «Сегодня», «Растяжка», «Прогресс», «Профиль» (§13.1,
// §20.12). Вкладки «Тренировки» на вебе нет. Календарь цикла открывается из
// Профиля и вкладкой не является.

import { NavLink } from 'react-router-dom'

export function BottomNav() {
  return (
    <nav className="bottom-nav" aria-label="Разделы">
      <NavLink to="/" end>
        Сегодня
      </NavLink>
      <NavLink to="/stretch">Растяжка</NavLink>
      <NavLink to="/progress">Прогресс</NavLink>
      <NavLink to="/profile">Профиль</NavLink>
    </nav>
  )
}
