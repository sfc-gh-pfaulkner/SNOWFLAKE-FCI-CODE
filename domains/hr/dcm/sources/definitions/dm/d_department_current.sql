DEFINE DYNAMIC TABLE {{db}}.DM.D_DEPARTMENT_CURRENT
    lag = '5 minutes'
    refresh_mode = 'AUTO'
    initialize = 'ON_CREATE'
    warehouse = HR_TRANSFORM_WH
as
select
    row_number() over (order by DEPARTMENT_ID) as DEPARTMENT_KEY,
    DEPARTMENT_ID,
    DEPARTMENT_NAME,
    COST_CENTER,
    BUSINESS_UNIT,
    MANAGER_EMPLOYEE_ID,
    ACTIVE_FLAG
from {{db}}.STG.V_DEPARTMENTS_CURRENT;
