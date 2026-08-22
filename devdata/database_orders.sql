create table if not exists sandbox_orders (
    order_id varchar(32) primary key,
    customer_id varchar(32) not null,
    region varchar(32) not null,
    amount decimal(12, 2) not null,
    status varchar(16) not null,
    created_at timestamp not null
);

insert into sandbox_orders (order_id, customer_id, region, amount, status, created_at) values
('ORD-1001', 'C-001', '华东', 128.50, 'PAID', '2026-08-20 09:15:00'),
('ORD-1002', 'C-002', '华南', 256.00, 'PAID', '2026-08-20 10:20:00'),
('ORD-1003', 'C-003', '华北', 89.90, 'PENDING', '2026-08-21 11:05:00'),
('ORD-1004', 'C-001', '华东', 512.75, 'PAID', '2026-08-21 14:40:00'),
('ORD-1005', 'C-004', '西南', 42.00, 'CANCELLED', '2026-08-22 08:30:00');
