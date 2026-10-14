# Análisis de la reunión

## 1. Migración de la base de datos de facturación (PostgreSQL 14 → 17)

**Contexto aportado por Lucía:** la migración está preparada en pruebas. Ha ensayado dos veces el volcado completo y tarda unas tres horas y media. Facturación no puede estar parada tanto tiempo en horario laboral.

**Opciones sobre la mesa**

| Opción | Defendida por | Argumento |
|---|---|---|
| A. Volcado completo el sábado 18 de octubre por la noche | Lucía (propuesta), con apoyo de Marta en lo relativo a la ventana | Evita una semana más de trabajo. Los dos ensayos no han fallado. Marta: el sábado por la noche apenas hay facturas manuales, así que el impacto para clientes sería mínimo si algo se cae. |
| B. Replicación lógica antes de migrar | Andrés | Reduciría el corte real a quince o veinte minutos. Sobre todo, si algo sale mal con el volcado no hay margen para volver atrás antes del lunes. |

**Objeción de Lucía a B:** hay unas cuarenta tablas sin clave primaria en el esquema antiguo de facturas que habría que revisar, lo que supone una semana más de trabajo.

**Decisión (propuesta por Yo, aceptada por los presentes):** volcado completo el sábado 18 de octubre a partir de las diez de la noche. En paralelo, Andrés prepara la replicación lógica como plan de respaldo para la siguiente ventana si el sábado falla.

**Postura final:** Andrés aceptó, pero dejó constancia de que sigue pensando que la replicación es más segura. Lucía dio el visto bueno.

**Compromisos**
- Lucía: runbook de la migración, compartido el miércoles 15.
- Andrés: replicación lógica probada en pruebas para el viernes 24 de octubre, incluidas las cuarenta tablas sin clave primaria.

## 2. Retraso del proveedor de pagos

**Situación (Marta):** la nueva API de reembolsos estaba prometida para el 1 de octubre y no ha llegado. El proveedor da ahora el 3 de noviembre, sin compromiso escrito. Mientras tanto, soporte hace unos sesenta reembolsos a la semana a mano.

| Opción | Defendida por | Argumento |
|---|---|---|
| Automatizar sobre la API antigua | Lucía (lo planteó como pregunta) | Aliviaría la carga manual. |
| No tocar la API antigua | Marta, Andrés | Marta: la retiran el 30 de noviembre. Andrés: no devuelve el identificador de la transacción original, y la conciliación sería "un infierno". |

**Decisión (Yo):** no se toca la API antigua. Lucía no insistió.

**Riesgo abierto:** si la API no llega y la campaña de noviembre duplica los reembolsos, faltaría una persona en soporte. Se revisa en la reunión del 3 de noviembre.

