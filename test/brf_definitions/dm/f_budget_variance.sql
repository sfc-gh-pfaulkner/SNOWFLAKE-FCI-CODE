DEFINE DYNAMIC TABLE {{db}}.DM.F_BUDGET_VARIANCE
    lag = '24 hours'
    refresh_mode = 'FULL'
    initialize = 'ON_CREATE'
    warehouse = {{transform_wh}}
as
select
    BUDGET_ID,
    FISCAL_YEAR,
    FISCAL_QUARTER,
    cc.COST_CENTER_KEY,
    COST_CENTER_NAME,
    DIVISION,
    ACCOUNT_ID,
    ACCOUNT_NAME,
    ACCOUNT_TYPE,
    BUDGET_AMOUNT,
    ACTUAL_AMOUNT,
    VARIANCE_AMOUNT,
    VARIANCE_PCT,
    CURRENCY_CODE,
    BUDGET_VERSION
from {{db}}.INT.V_BUDGET_WITH_VARIANCE bv
left join {{db}}.DM.D_COST_CENTER cc on bv.COST_CENTER_ID = cc.COST_CENTER_ID;
