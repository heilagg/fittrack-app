import Foundation

//  Валидатор библиотеки упражнений и шаблонов растяжки.
//
//  Проверки (SPEC §17, этап 2):
//    - сумма muscle_contributions ≈ 1.0, все слаги мышц из списка SPEC §6.4
//    - alternatives ведут на существующие слаги
//    - progression_family связна; family_load_ratio задан у каждого
//      упражнения семьи размером > 1
//    - каждая комбинация (тип дня × акцент × уровень инвентаря) покрыта
//      минимум тремя упражнениями — иначе домашний пользователь упрётся
//      в пустой подбор
//    - joint_stress и impact заданы, значения из допустимого множества
//    - каждое значение equipment — из словаря SPEC §6.6; load_type
//      kettlebell/cable/machine называет свой снаряд в equipment
//
//  Ненулевой код возврата = красный CI.

FileHandle.standardError.write(Data("content-validator: не реализован (этап 2)\n".utf8))
exit(1)
