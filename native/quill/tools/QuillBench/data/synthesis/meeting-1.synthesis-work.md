## Decisiones

- Migración de PostgreSQL 14 a 17: volcado completo el sábado 18 de octubre a partir de las 22:00.
- Andrés prepara la replicación lógica como plan de respaldo para la siguiente ventana si el sábado falla.
- No se automatiza nada sobre la API antigua de reembolsos del proveedor de pagos.
- Lanzamiento de la app móvil: iOS el 10 de noviembre y Android el 17 de noviembre.
- Aprobada la ampliación del volumen de disco del entorno de pruebas; Lucía la hace directamente, sin esperar a la reunión.

## Tareas

| Responsable | Tarea | Fecha |
|---|---|---|
| Lucía | Compartir el runbook de la migración | miércoles 15 de octubre |
| Andrés | Tener la replicación lógica probada en pruebas (incluidas las cuarenta tablas sin clave primaria) | viernes 24 de octubre |
| Marta | Pedir al proveedor de pagos por escrito la fecha del 3 de noviembre | hoy (día de la reunión) |
| Marta | Si el proveedor no confirma antes del 20 de octubre, escalar a su responsable de cuenta | 20 de octubre |
| Marta | Preparar mensaje a usuarios de Android explicando que su versión llega una semana después | 7 de noviembre |
| Diego | Enviar la versión de iOS a revisión de Apple | lunes 27 de octubre |
| Lucía | Ampliar el volumen de disco del entorno de pruebas | sin fecha |

## Riesgos y temas abiertos

- Volcado completo: puede fallar a mitad; los datos de producción son un 30 % más grandes que los de pruebas y los dos ensayos no fallaron. Si falla, no hay margen para volver atrás antes del lunes (Andrés), cuando entra el volumen de facturación recurrente (Marta).
- API de reembolsos: la nueva debía llegar el 1 de octubre; la nueva fecha, 3 de noviembre, no tiene compromiso por escrito. La antigua se retira el 30 de noviembre.
- Soporte hace unos sesenta reembolsos manuales a la semana. Si la API no llega y la campaña de noviembre duplica los reembolsos, faltaría una persona en soporte. Se revisa en la reunión del 3 de noviembre.
- Android: va una semana por detrás por problemas del SDK de notificaciones con Android 15. Diego dice que el 10 de noviembre era posible pero "muy justo".
- Revisión de Apple de iOS: riesgo de rechazo; por eso se envía el 27 de octubre, para tener margen.
- Entorno de pruebas: se quedaba sin espacio en unas dos semanas (se resuelve con la ampliación aprobada).

## Desacuerdos

- **Migración:** Andrés sigue pensando que la replicación lógica (corte de 15-20 minutos) es más segura que el volcado completo, aunque aceptó la decisión.
- **Lanzamiento de la app:** Marta prefería lanzar iOS y Android a la vez, para evitar consultas de usuarios de Android. Diego y Andrés defendieron lanzarlas por separado para no perder la ventana de la campaña en iOS. Se decidió lanzarlas por separado; Marta aceptó preparar el mensaje.
