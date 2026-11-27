CREATE DATABASE IF NOT EXISTS hrms_db DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE hrms_db;

-- 1. 部门表
CREATE TABLE IF NOT EXISTS hr_department (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    parent_id BIGINT NOT NULL DEFAULT 0 COMMENT '父部门ID，0表示顶级部门',
    dept_name VARCHAR(64) NOT NULL COMMENT '部门名称',
    leader_name VARCHAR(64) DEFAULT NULL COMMENT '部门负责人姓名',
    headcount_limit INT NOT NULL DEFAULT 20 COMMENT '编制人数',
    description VARCHAR(255) DEFAULT NULL COMMENT '部门描述',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_parent_id (parent_id)
) ENGINE=InnoDB COMMENT='组织部门表';

-- 2. 岗位表
CREATE TABLE IF NOT EXISTS hr_position (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    pos_code VARCHAR(32) NOT NULL UNIQUE COMMENT '岗位编码',
    pos_name VARCHAR(64) NOT NULL COMMENT '岗位名称',
    dept_id BIGINT NOT NULL COMMENT '所属部门ID',
    level_range VARCHAR(32) DEFAULT 'P5-P7' COMMENT '职级范围',
    min_salary DECIMAL(10, 2) NOT NULL DEFAULT 6000.00,
    max_salary DECIMAL(10, 2) NOT NULL DEFAULT 20000.00,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_pos_dept (dept_id)
) ENGINE=InnoDB COMMENT='岗位职级表';

-- 3. 员工档案主表
CREATE TABLE IF NOT EXISTS hr_employee (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    emp_no VARCHAR(32) NOT NULL UNIQUE COMMENT '工号',
    name VARCHAR(64) NOT NULL COMMENT '姓名',
    gender TINYINT NOT NULL DEFAULT 1 COMMENT '1男 2女',
    phone VARCHAR(20) NOT NULL COMMENT '手机号',
    email VARCHAR(100) DEFAULT NULL COMMENT '邮箱',
    id_card VARCHAR(32) DEFAULT NULL COMMENT '身份证号（脱敏展示）',
    dept_id BIGINT NOT NULL COMMENT '部门ID',
    position_id BIGINT DEFAULT NULL COMMENT '岗位ID',
    position_name VARCHAR(64) NOT NULL COMMENT '岗位名称冗余',
    base_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '月基本薪资',
    annual_leave_balance DECIMAL(4, 1) NOT NULL DEFAULT 5.0 COMMENT '剩余年假天数',
    hire_date DATE NOT NULL COMMENT '入职日期',
    probation_end_date DATE DEFAULT NULL COMMENT '预计转正日期',
    contract_end_date DATE DEFAULT NULL COMMENT '合同到期日期',
    resign_date DATE DEFAULT NULL COMMENT '离职日期',
    resign_reason VARCHAR(255) DEFAULT NULL COMMENT '离职原因',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'PROBATION/ACTIVE/RESIGNED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_emp_dept (dept_id),
    INDEX idx_emp_status (status),
    INDEX idx_contract_end (contract_end_date)
) ENGINE=InnoDB COMMENT='员工档案表';

-- 4. 员工异动记录表（转正/调岗/调薪）
CREATE TABLE IF NOT EXISTS hr_emp_transfer (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    transfer_type VARCHAR(20) NOT NULL COMMENT 'REGULARIZE/TRANSFER/SALARY_ADJUST/RESIGN',
    before_dept_id BIGINT DEFAULT NULL,
    after_dept_id BIGINT DEFAULT NULL,
    before_position VARCHAR(64) DEFAULT NULL,
    after_position VARCHAR(64) DEFAULT NULL,
    before_salary DECIMAL(10, 2) DEFAULT NULL,
    after_salary DECIMAL(10, 2) DEFAULT NULL,
    effective_date DATE NOT NULL COMMENT '生效日期',
    remark VARCHAR(255) DEFAULT NULL,
    operator_id BIGINT DEFAULT NULL COMMENT '操作人用户ID',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_transfer_emp (employee_id)
) ENGINE=InnoDB COMMENT='员工异动历史表';

-- 5. 系统用户表
CREATE TABLE IF NOT EXISTS sys_user (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    username VARCHAR(64) NOT NULL UNIQUE COMMENT '登录账号',
    password_hash VARCHAR(128) NOT NULL COMMENT '加盐SHA256哈希',
    role VARCHAR(20) NOT NULL DEFAULT 'EMPLOYEE' COMMENT 'ADMIN/HR/MANAGER/EMPLOYEE',
    employee_id BIGINT DEFAULT NULL COMMENT '关联员工ID',
    is_active TINYINT(1) NOT NULL DEFAULT 1 COMMENT '1启用 0禁用',
    last_login_at DATETIME DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_user_emp (employee_id)
) ENGINE=InnoDB COMMENT='系统用户表';

-- 6. 考勤打卡记录表
CREATE TABLE IF NOT EXISTS hr_attendance (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    work_date DATE NOT NULL COMMENT '考勤日期',
    clock_in_time DATETIME DEFAULT NULL COMMENT '上班打卡时间',
    clock_out_time DATETIME DEFAULT NULL COMMENT '下班打卡时间',
    late_minutes INT NOT NULL DEFAULT 0 COMMENT '迟到分钟数',
    early_minutes INT NOT NULL DEFAULT 0 COMMENT '早退分钟数',
    status VARCHAR(24) NOT NULL DEFAULT 'NORMAL' COMMENT 'NORMAL/LATE/EARLY_LEAVE/LATE_AND_EARLY/ABSENT',
    remark VARCHAR(255) DEFAULT NULL COMMENT '异常说明或补卡备注',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_emp_date (employee_id, work_date),
    INDEX idx_att_date (work_date)
) ENGINE=InnoDB COMMENT='考勤打卡表';

-- 7. 请假与加班申请表
CREATE TABLE IF NOT EXISTS hr_leave_overtime (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '申请人ID',
    category VARCHAR(20) NOT NULL DEFAULT 'LEAVE' COMMENT 'LEAVE请假 / OVERTIME加班',
    sub_type VARCHAR(20) NOT NULL COMMENT 'ANNUAL/SICK/PERSONAL/MARRIAGE/WORKDAY_OT/WEEKEND_OT',
    start_time DATETIME NOT NULL COMMENT '开始时间',
    end_time DATETIME NOT NULL COMMENT '结束时间',
    duration DECIMAL(5, 1) NOT NULL COMMENT '时长（请假为天，加班为小时）',
    reason VARCHAR(500) NOT NULL COMMENT '事由',
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING(单级待审批)/PENDING_MGR(长假一级待主管审批)/PENDING_HR(长假二级待HR审批)/APPROVED/REJECTED/CANCELLED；PENDING_MGR 与 PENDING_HR 同属未终态',
    approver_id BIGINT DEFAULT NULL COMMENT '最近一次处理该单的用户ID',
    approve_remark VARCHAR(255) DEFAULT NULL COMMENT '最近一次审批意见',
    approved_at DATETIME DEFAULT NULL COMMENT '进入终态(APPROVED/REJECTED)的时间；中间态记录最近一次推进时间',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_lo_emp_status (employee_id, status),
    INDEX idx_lo_category (category)
) ENGINE=InnoDB COMMENT='请假与加班审批表';

-- 8. 绩效考核表
CREATE TABLE IF NOT EXISTS hr_performance (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    cycle_name VARCHAR(32) NOT NULL COMMENT '考核周期，如 2026-Q4',
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    self_summary VARCHAR(1000) DEFAULT NULL COMMENT '员工自评总结',
    self_score DECIMAL(5, 1) DEFAULT NULL COMMENT '员工自评分',
    final_score DECIMAL(5, 1) DEFAULT NULL COMMENT '最终得分',
    grade VARCHAR(8) DEFAULT NULL COMMENT 'S/A/B/C/D',
    bonus_ratio DECIMAL(4, 2) NOT NULL DEFAULT 1.00 COMMENT '绩效系数',
    reviewer_id BIGINT DEFAULT NULL COMMENT '评审人用户ID',
    reviewer_comment VARCHAR(500) DEFAULT NULL COMMENT '评审评语',
    status VARCHAR(20) NOT NULL DEFAULT 'SELF_EVAL' COMMENT 'SELF_EVAL/REVIEWING/COMPLETED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_cycle_emp (cycle_name, employee_id)
) ENGINE=InnoDB COMMENT='绩效考核表';

-- 9. 月度薪资表
CREATE TABLE IF NOT EXISTS hr_payroll (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    pay_month VARCHAR(7) NOT NULL COMMENT '发薪月份 YYYY-MM',
    base_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00,
    bonus DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '绩效及津贴奖金',
    overtime_pay DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '加班补贴',
    attendance_deduction DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '考勤及事假扣款',
    social_security DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '五险一金个人部分',
    tax DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '个人所得税',
    net_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '实发工资',
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT' COMMENT 'DRAFT/PAID',
    paid_at DATETIME DEFAULT NULL,
    remark VARCHAR(255) DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_emp_month (employee_id, pay_month)
) ENGINE=InnoDB COMMENT='月度薪资核算表';

-- 10. 招聘候选人表
CREATE TABLE IF NOT EXISTS hr_recruitment_candidate (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(64) NOT NULL COMMENT '候选人姓名',
    gender TINYINT NOT NULL DEFAULT 1,
    phone VARCHAR(20) NOT NULL,
    email VARCHAR(100) DEFAULT NULL,
    target_dept_id BIGINT NOT NULL COMMENT '目标部门ID',
    target_position VARCHAR(64) NOT NULL COMMENT '应聘岗位',
    expected_salary DECIMAL(10, 2) DEFAULT 10000.00,
    source VARCHAR(32) DEFAULT 'BOSS直聘' COMMENT '简历来源',
    stage VARCHAR(20) NOT NULL DEFAULT 'NEW' COMMENT 'NEW/INTERVIEW/OFFER/HIRED/REJECTED',
    interview_notes VARCHAR(500) DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_cand_stage (stage)
) ENGINE=InnoDB COMMENT='招聘候选人表';

-- 11. 系统审计日志表
CREATE TABLE IF NOT EXISTS sys_audit_log (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id BIGINT DEFAULT NULL,
    username VARCHAR(64) DEFAULT NULL,
    module VARCHAR(32) NOT NULL COMMENT '操作模块',
    action VARCHAR(64) NOT NULL COMMENT '操作动作',
    detail VARCHAR(500) DEFAULT NULL COMMENT '操作详情',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_audit_time (created_at)
) ENGINE=InnoDB COMMENT='操作审计日志表';

-- 12. 审批链历史表（P3.1 长假二级审批）
-- 一条申请单对应 1~2 行：step=1 主管（或单级审批人）、step=2 HR 二级。
-- UNIQUE(request_id, step) 保证「同一步骤不可重复推进」，是并发双击审批的最后一道防线。
CREATE TABLE IF NOT EXISTS hr_approval_log (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    request_id BIGINT NOT NULL COMMENT '申请单ID(hr_leave_overtime.id)',
    step INT NOT NULL COMMENT '审批级次：1=一级(主管/单级)，2=二级(HR)',
    approver_id BIGINT NOT NULL COMMENT '处理人用户ID',
    approver_name VARCHAR(64) NOT NULL COMMENT '处理人登录名快照',
    approver_role VARCHAR(20) NOT NULL COMMENT '处理人角色快照(MANAGER/HR/ADMIN)',
    action VARCHAR(20) NOT NULL COMMENT 'APPROVED/REJECTED',
    result_status VARCHAR(20) NOT NULL COMMENT '本次动作后的单据状态',
    remark VARCHAR(255) DEFAULT NULL COMMENT '本级审批意见',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_al_request_step (request_id, step),
    INDEX idx_al_request (request_id)
) ENGINE=InnoDB COMMENT='审批链历史表';

-- 13. 站内通知表（P3.2 通知中心）
-- 四类触发：合同 30 天内到期 / 审批结果（含长假转二级）/ 工资条发放 / 培训计划发布。
-- UNIQUE(user_id, type, ref_id) 是幂等的关键：重复发薪、工作台反复刷新、同一门课反复发布都不会堆出第二条。
--   ref_id 取值——PAYROLL_PAID=工资单ID；LEAVE_*=申请单ID；TRAINING_PUBLISHED=培训计划ID；
--   CONTRACT_EXPIRING=`员工ID:到期日`（续签后到期日变化即可重新提醒）。
-- user_id 与 sys_user.id 同为 BIGINT；read_flag 用 TINYINT(1) 与全库布尔列风格一致。
CREATE TABLE IF NOT EXISTS sys_notification (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id BIGINT NOT NULL COMMENT '接收人(sys_user.id)',
    type VARCHAR(30) NOT NULL COMMENT 'CONTRACT_EXPIRING/LEAVE_APPROVED/LEAVE_REJECTED/LEAVE_NEXT_LEVEL/PAYROLL_PAID/TRAINING_PUBLISHED/EXPENSE_SUBMITTED/EXPENSE_APPROVED/EXPENSE_REJECTED/EXPENSE_PAID',
    title VARCHAR(120) NOT NULL COMMENT '标题（代码拼装，不含用户输入）',
    content VARCHAR(500) DEFAULT NULL COMMENT '正文（代码拼装，不含用户输入）',
    ref_id VARCHAR(64) NOT NULL DEFAULT '' COMMENT '业务跳转键，见上方注释',
    read_flag TINYINT(1) NOT NULL DEFAULT 0 COMMENT '0=未读，1=已读',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_notif_user_type_ref (user_id, type, ref_id),
    INDEX idx_notif_user_read (user_id, read_flag)
) ENGINE=InnoDB COMMENT='站内通知表';

-- 14. 培训计划表（P4.1 培训与学分）
-- 状态机：DRAFT ->(发布) PUBLISHED ->(结课) DONE ；DRAFT/PUBLISHED ->(取消) CANCELLED。
-- DONE/CANCELLED 为终态，推进与校验全部在 training_controller.trainingStatusTransition 里，
-- 数据库不设触发器——和 hr_leave_overtime 一样把状态规则留在唯一一处实现，避免两处漂移。
-- dept_id = 0 表示全员可见；capacity = 0 表示不限名额（培训名额天然有「不限」这一档）。
CREATE TABLE IF NOT EXISTS hr_training (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    title VARCHAR(120) NOT NULL COMMENT '培训主题',
    category VARCHAR(20) NOT NULL DEFAULT 'INTERNAL' COMMENT 'INTERNAL内部培训/ONLINE在线课程/EXTERNAL外部课程/COMPLIANCE合规必修',
    trainer VARCHAR(64) NOT NULL DEFAULT '' COMMENT '讲师/机构',
    dept_id BIGINT NOT NULL DEFAULT 0 COMMENT '面向部门ID，0=全员',
    start_time DATETIME NOT NULL COMMENT '开课时间',
    end_time DATETIME NOT NULL COMMENT '结课时间',
    capacity INT NOT NULL DEFAULT 0 COMMENT '名额上限，0=不限',
    credit DECIMAL(4, 1) NOT NULL DEFAULT 1.0 COMMENT '本课程学分',
    location VARCHAR(120) NOT NULL DEFAULT '' COMMENT '地点或线上链接',
    description VARCHAR(500) DEFAULT NULL COMMENT '课程简介',
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT' COMMENT 'DRAFT/PUBLISHED/DONE/CANCELLED',
    creator_id BIGINT NOT NULL DEFAULT 0 COMMENT '发布人用户ID(sys_user.id)',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_training_status (status),
    INDEX idx_training_start (start_time),
    INDEX idx_training_dept (dept_id)
) ENGINE=InnoDB COMMENT='培训计划表';

-- 15. 培训报名与学分记录表（P4.1）
-- 一人一课一行（UNIQUE），报名/签到/考核都写同一行，不额外建签到表：
-- 三态共用一行才能天然防「重复报名」「重复签到」「重复录分」。
-- score 为 NULL 表示该课无考核环节或尚未录入；credit 由后端按培训学分与分数算出，前端只读。
-- status：REGISTERED 已报名 / ATTENDED 已出勤 / ABSENT 缺席 / CANCELLED 已取消报名。
CREATE TABLE IF NOT EXISTS hr_training_record (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    training_id BIGINT NOT NULL COMMENT '培训计划ID(hr_training.id)',
    employee_id BIGINT NOT NULL COMMENT '员工ID(hr_employee.id)',
    status VARCHAR(20) NOT NULL DEFAULT 'REGISTERED' COMMENT 'REGISTERED/ATTENDED/ABSENT/CANCELLED',
    checkin_at DATETIME DEFAULT NULL COMMENT '签到时间',
    score DECIMAL(5, 1) DEFAULT NULL COMMENT '考核得分（0-100），NULL=未考核/未录入',
    credit DECIMAL(4, 1) NOT NULL DEFAULT 0.0 COMMENT '实际获得学分',
    remark VARCHAR(255) DEFAULT NULL COMMENT 'HR 备注（缺席原因等）',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_tr_training_emp (training_id, employee_id),
    INDEX idx_tr_emp_status (employee_id, status)
) ENGINE=InnoDB COMMENT='培训报名与学分记录表';

-- ==========================================
-- 初始演示数据（Seed Data）
-- ==========================================
INSERT IGNORE INTO hr_department (id, parent_id, dept_name, leader_name, headcount_limit, description) VALUES
(1, 0, '总经办', '张明远', 5, '公司战略决策与经营管理'),
(2, 1, '技术研发中心', '李泽宇', 50, '核心产品架构、仓颉后端与Web研发'),
(3, 1, '人力资源部', '王静', 10, '招聘配置、薪酬绩效与员工关系'),
(4, 1, '市场与产品部', '赵晨', 25, '产品规划、品牌推广与商业化');

INSERT IGNORE INTO hr_position (id, pos_code, pos_name, dept_id, level_range, min_salary, max_salary) VALUES
(1, 'POS-CIO', '首席信息官', 1, 'M4', 25000.00, 45000.00),
(2, 'POS-DEV-CJ', '仓颉后端工程师', 2, 'P6-P8', 15000.00, 32000.00),
(3, 'POS-DEV-FE', '资深前端工程师', 2, 'P6-P7', 14000.00, 28000.00),
(4, 'POS-HRBP', '资深 HRBP', 3, 'P6-P7', 10000.00, 18000.00),
(5, 'POS-PM', '高级产品经理', 4, 'P6-P8', 16000.00, 30000.00);

INSERT IGNORE INTO hr_employee (id, emp_no, name, gender, phone, email, dept_id, position_id, position_name, base_salary, annual_leave_balance, hire_date, contract_end_date, status) VALUES
(1, 'EMP20260001', '张明远', 1, '13800000001', 'admin@hrms.local', 1, 1, '首席信息官', 30000.00, 10.0, '2023-01-10', '2028-01-09', 'ACTIVE'),
(2, 'EMP20260002', '王静', 2, '13800000002', 'hr@hrms.local', 3, 4, '资深 HRBP', 14000.00, 8.0, '2023-06-01', '2027-05-31', 'ACTIVE'),
(3, 'EMP20260003', '李泽宇', 1, '13800000003', 'manager@hrms.local', 2, 2, '研发总监', 26000.00, 10.0, '2024-02-01', '2027-01-31', 'ACTIVE'),
(4, 'EMP20260004', '陈思远', 1, '13800000004', 'dev01@hrms.local', 2, 2, '仓颉后端工程师', 19000.00, 5.0, '2025-07-01', '2026-12-15', 'ACTIVE'),
(5, 'EMP20260005', '林小满', 2, '13800000005', 'fe01@hrms.local', 2, 3, '资深前端工程师', 17500.00, 5.0, '2026-09-01', '2029-08-31', 'PROBATION');

INSERT IGNORE INTO hr_recruitment_candidate (id, name, gender, phone, email, target_dept_id, target_position, expected_salary, source, stage, interview_notes) VALUES
(1, '周星辰', 1, '13911112222', 'zhou@example.com', 2, '仓颉后端工程师', 20000.00, 'BOSS直聘', 'OFFER', '技术面表现优秀，熟悉仓颉并发模型'),
(2, '吴雨桐', 2, '13933334444', 'wu@example.com', 4, '高级产品经理', 18000.00, '猎聘', 'INTERVIEW', '已完成一面，待复试');

-- 培训计划种子数据：开课时间用 NOW() 相对量表达，保证任何时候重建库都能演示
-- 「可报名 / 签到窗口内 / 已结课」三种状态，而不是依赖某一次固定的日历快照。
INSERT IGNORE INTO hr_training (id, title, category, trainer, dept_id, start_time, end_time, capacity, credit, location, description, status, creator_id) VALUES
(1, '仓颉语言工程实践：从并发到数据访问层', 'INTERNAL', '李泽宇', 2, NOW() + INTERVAL 3 DAY, NOW() + INTERVAL 3 DAY + INTERVAL 5 HOUR, 30, 2.0, '总部 3F 路演厅', '面向研发的仓颉实操课，覆盖协程、并发模型与 MySQL 数据访问层加固。', 'PUBLISHED', 2),
(2, '信息安全与合规必修（年度）', 'COMPLIANCE', '外部讲师 · 安永', 0, NOW() + INTERVAL 7 DAY, NOW() + INTERVAL 7 DAY + INTERVAL 2 HOUR, 0, 1.0, '线上直播', '全员必修，未获得学分将影响年度绩效评级。', 'PUBLISHED', 2),
(3, '高效绩效面谈技巧', 'ONLINE', '王静', 3, NOW() - INTERVAL 10 DAY, NOW() - INTERVAL 10 DAY + INTERVAL 2 HOUR, 20, 1.5, '飞书会议室', '面向 HRBP 与部门主管的面谈方法论，含录像回放。', 'DONE', 2),
(4, '新员工入职引导（草稿）', 'INTERNAL', '王静', 0, NOW() + INTERVAL 15 DAY, NOW() + INTERVAL 15 DAY + INTERVAL 3 HOUR, 50, 1.0, '总部 2F 培训室', '草稿状态，尚未发布，员工端不可见。', 'DRAFT', 2);

-- 第 3 课（已结课）的成绩与学分：88 分全额学分、55 分不合格零学分。
INSERT IGNORE INTO hr_training_record (id, training_id, employee_id, status, checkin_at, score, credit, remark) VALUES
(1, 3, 2, 'ATTENDED', NOW() - INTERVAL 10 DAY, 88.0, 1.5, NULL),
(2, 3, 4, 'ATTENDED', NOW() - INTERVAL 10 DAY, 55.0, 0.0, '补考安排在下季度'),
(3, 3, 5, 'ABSENT', NULL, NULL, 0.0, '入职当周未参加');

-- 16. 差旅与报销表（P4.2）
-- 状态机：DRAFT ->(submit) SUBMITTED ->(approve) APPROVED ->(pay) PAID；
--         SUBMITTED ->(reject) REJECTED；REJECTED ->(submit) SUBMITTED（修改后重报）；
--         SUBMITTED ->(withdraw) DRAFT（本人撤回）；PAID 为终态。
-- 判定逻辑全部在 expense_controller.cj 的纯函数里，这里只负责把「不该发生的组合」挡在库外。
-- receipt_no 允许 NULL（小额无票场景）：MySQL 的 UNIQUE 允许多行 NULL，
-- 因此「无票」不会被误判成重复票号，而真实票号仍然同员工同月唯一。
CREATE TABLE IF NOT EXISTS hr_expense (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '报销人(hr_employee.id)',
    category VARCHAR(20) NOT NULL DEFAULT 'OTHER' COMMENT 'TRAVEL差旅/TRANSPORT交通/MEAL餐费/OFFICE办公/OTHER其他',
    title VARCHAR(120) NOT NULL COMMENT '报销事由',
    amount DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '报销金额（元），实报实销，不计入 hr_payroll 应税项',
    occur_date DATE NOT NULL COMMENT '费用发生日期',
    pay_month VARCHAR(7) NOT NULL COMMENT '报销所属月份 YYYY-MM，必须等于 occur_date 所在月',
    city VARCHAR(64) NOT NULL DEFAULT '' COMMENT '出差城市，仅 TRAVEL 必填',
    days INT NOT NULL DEFAULT 0 COMMENT '出差天数，仅 TRAVEL 有效（1-60），非差旅恒为 0',
    receipt_no VARCHAR(64) DEFAULT NULL COMMENT '发票号，同员工同月唯一（NULL=无票）',
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT' COMMENT 'DRAFT/SUBMITTED/APPROVED/REJECTED/PAID',
    submit_user_id BIGINT NOT NULL DEFAULT 0 COMMENT '提交人用户ID(sys_user.id)，0=尚未提交；用于自审闸门',
    submitted_at DATETIME DEFAULT NULL COMMENT '提交时间（撤回后清空）',
    approver_user_id BIGINT NOT NULL DEFAULT 0 COMMENT '审批人用户ID，0=未审批',
    approve_remark VARCHAR(255) DEFAULT NULL COMMENT '审批意见',
    approved_at DATETIME DEFAULT NULL COMMENT '审批时间（通过或驳回都写）',
    paid_at DATETIME DEFAULT NULL COMMENT '报销款发放时间',
    paid_by BIGINT NOT NULL DEFAULT 0 COMMENT '发放操作人用户ID',
    remark VARCHAR(255) DEFAULT NULL COMMENT '报销人备注',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_expense_emp_month_receipt (employee_id, pay_month, receipt_no),
    KEY idx_expense_emp_month (employee_id, pay_month),
    KEY idx_expense_status (status)
) ENGINE=InnoDB COMMENT='差旅与报销表';

-- 报销种子数据：occurrence 用 NOW() 相对量表达，pay_month 由同一个偏移量算出，
-- 保证任何时候重建库都满足「月份一致」闸门（这是本模块最强的业务约束）。
-- 覆盖：5 个类别 / 5 个状态各至少 1 条 / 1 笔 >5000 的差旅（演示审批档位）/
--       1 笔 TRAVEL 带 city+days / 同一员工同一月两张不同票号（演示 UNIQUE 只挡重复票号）。
-- ⚠️ 刻意不放「同员工同月重复票号」的负例：那会被 UNIQUE 直接拒绝，种子会静默少一行。
INSERT IGNORE INTO hr_expense (id, employee_id, category, title, amount, occur_date, pay_month, city, days, receipt_no, status, submit_user_id, submitted_at, approver_user_id, approve_remark, approved_at, paid_at, paid_by, remark) VALUES
(1, 4, 'TRAVEL', '上海客户现场支持差旅', 4860.00, DATE_FORMAT(NOW() - INTERVAL 45 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 45 DAY, '%Y-%m'), '上海', 4, 'FP2026SH0401', 'PAID', 4, NOW() - INTERVAL 44 DAY, 2, '客户项目必要支出，同意', NOW() - INTERVAL 43 DAY, NOW() - INTERVAL 40 DAY, 2, '含住宿与市内交通'),
(2, 4, 'TRANSPORT', '往返高铁票（上海）', 1128.00, DATE_FORMAT(NOW() - INTERVAL 45 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 45 DAY, '%Y-%m'), '', 0, 'FP2026SH0402', 'APPROVED', 4, NOW() - INTERVAL 44 DAY, 2, '与差旅单同批，同意', NOW() - INTERVAL 43 DAY, NULL, 0, NULL),
(3, 4, 'MEAL', '客户接待餐费', 680.50, DATE_FORMAT(NOW() - INTERVAL 12 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 12 DAY, '%Y-%m'), '', 0, 'FP2026SH0403', 'SUBMITTED', 4, NOW() - INTERVAL 10 DAY, 0, NULL, NULL, NULL, 0, '3 人工作餐'),
(4, 4, 'OFFICE', '机械键盘与鼠标套装', 1299.00, DATE_FORMAT(NOW() - INTERVAL 5 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 5 DAY, '%Y-%m'), '', 0, NULL, 'DRAFT', 0, NULL, 0, NULL, NULL, NULL, 0, '研发工位设备，待补发票'),
(5, 5, 'TRAVEL', '深圳行业展会出差', 7260.00, DATE_FORMAT(NOW() - INTERVAL 20 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 20 DAY, '%Y-%m'), '深圳', 6, 'FP2026SZ0501', 'SUBMITTED', 0, NOW() - INTERVAL 18 DAY, 0, NULL, NULL, NULL, 0, '含展会期间住宿'),
(6, 5, 'MEAL', '团队建设聚餐', 356.00, DATE_FORMAT(NOW() - INTERVAL 70 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 70 DAY, '%Y-%m'), '', 0, 'FP2026TS0502', 'REJECTED', 0, NOW() - INTERVAL 69 DAY, 3, '缺少合规发票，请补充后重报', NOW() - INTERVAL 66 DAY, NULL, 0, NULL),
(7, 3, 'TRANSPORT', '客户拜访市内交通', 268.00, DATE_FORMAT(NOW() - INTERVAL 30 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 30 DAY, '%Y-%m'), '', 0, 'FP2026BJ0301', 'APPROVED', 3, NOW() - INTERVAL 29 DAY, 2, '属实，同意', NOW() - INTERVAL 28 DAY, NULL, 0, NULL),
(8, 3, 'OFFICE', '显示器支架 2 件', 890.00, DATE_FORMAT(NOW() - INTERVAL 30 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 30 DAY, '%Y-%m'), '', 0, 'FP2026BJ0302', 'PAID', 3, NOW() - INTERVAL 29 DAY, 2, '行政采购，同意', NOW() - INTERVAL 28 DAY, NOW() - INTERVAL 25 DAY, 2, NULL),
(9, 2, 'TRAVEL', '杭州校园招聘宣讲差旅', 3180.00, DATE_FORMAT(NOW() - INTERVAL 12 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 12 DAY, '%Y-%m'), '杭州', 2, 'FP2026HZ0201', 'SUBMITTED', 2, NOW() - INTERVAL 11 DAY, 0, NULL, NULL, NULL, 0, '两天三场宣讲'),
(10, 2, 'OTHER', '客户答谢伴手礼', 880.00, DATE_FORMAT(NOW() - INTERVAL 12 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 12 DAY, '%Y-%m'), '', 0, 'FP2026HZ0202', 'PAID', 2, NOW() - INTERVAL 11 DAY, 1, '市场费用，同意', NOW() - INTERVAL 10 DAY, NOW() - INTERVAL 8 DAY, 1, NULL),
(11, 1, 'TRAVEL', '北京总部季度战略会差旅', 18600.00, DATE_FORMAT(NOW() - INTERVAL 15 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 15 DAY, '%Y-%m'), '北京', 5, 'FP2026BJ0101', 'SUBMITTED', 1, NOW() - INTERVAL 14 DAY, 0, NULL, NULL, NULL, 0, '大额差旅，须由 ADMIN/HR 审批'),
(12, 1, 'MEAL', '总部商务宴请', 320.00, DATE_FORMAT(NOW() - INTERVAL 60 DAY, '%Y-%m-%d'), DATE_FORMAT(NOW() - INTERVAL 60 DAY, '%Y-%m'), '', 0, 'FP2026BJ0102', 'DRAFT', 0, NULL, 0, NULL, NULL, NULL, 0, '待确认陪同人数');
