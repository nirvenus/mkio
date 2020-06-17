/*
		В модуле реализованы режимы работы как ОУ(Оконечное устройство - slave)
	так и КШ(Контролер шины - Master) по каналу МКИО на устройстве HI-1575.
	Форматы сообщений 1 и 2 по ГОСТ-2003 МКИО
*/

module mkio
(
//Тактовые частоты
input clock_100,
input clock_12,
input reset_b,

// Технологический режим
input usb_test_on,

//Для взаимодействия с HI-1575
input pin_rcva,									//Принято сообщение по шине А
input pin_rcvb,									//Принято сообщение по шине B
output pin_reg,									//Настройка режима HI-1575 (1) / доступ к передаваемым данным (0)
output pin_r_w,									//чтение (1) / запись (0)
output pin_strb_n,								//Сигнал начала обмена данными
output pin_mr,									//Сброс HI-1575 (при лог. единице)
inout pin_sync,									//Синхронизация. 1 - командное слово, 0 - данные
inout [15 : 0] pin_d,							//Параллельный порт данных
output pin_clk_12,								//Тактовая частота для HI-1575
output pin_cha_chb,								//Выбор канала (0 - А, 1 - B)
//input pin_error,

// Для обмена данными по протоколу МКИО
	// Общие
	input mkio_en,				// Режим обмена по МКИО включен
	output reg 	[15 : 0] mkio_data_words_rx [31 : 0],	// Буфер полученных СД
	output reg mkio_ready_rx = 1'b0,	// 1 - приняты данные по МКИО
	output mkio_ready,				// Готовность для приема/передачи данных
	output reg [15 : 0] mkio_FA00_reg_rx = 16'h0,		// Комндное слово полученное в режиме ОУ (если команда на прием) или отправленное в режиме КШ (если команда на прием), содержится подадрес и кол-во принятых слов
	input [15 : 0] mkio_100_reg_tx,		// параметры для записи в RAM или КС если КШ - асихронный режим
	output [2 : 0] mkio_status,			// Состояние обмена по МКИО	(регистр F900)
	
	// ОУ
	input [4 : 0] mkio_slave_address,				// Собственный адрес ОУ в режиме ОУ
	
	// КШ
	input mkio_master,							// 1 - режим КШ (master), 0 - ОУ (slave)
	input mkio_master_cycle_mode,					// Асинхронный обмен или Циклический
	input mkio_master_w_r,							// Чтение (1) с ОУ или Передача (0)
	input [4 : 0] mkio_master_cycle_subaddress,		// Подадрес для обмена в циклическом режиме
	input mkio_master_start,						// Сигнал начала приема/передачи данных в режиме КШ
	output reg [2 : 0] mkio_master_exchange_error_counter = 3'd0,	// Счетчик неудачных попыток обмена с ОУ в режиме КШ
	
	// RAM
	input [15 : 0] mkio_ram_data_words_tx [31 : 0],	// Буфер СД для записи в RAM (или передачи если КШ асихронный обмен)
	input mkio_ram_write_sign			// сигнал записи в RAM если КШ циклический обмен или ОУ
);

// Порты для МК HI-1575
	// ЧТЕНИЕ
	wire [15 : 0] hi_1575_data_rx;			// Данные полученные по МКИО
	wire hi_1575_cha_chb_rx;				// По какому каналу приняты данные (0 - А, 1 - B)
	wire [1 : 0] hi_1575_data_received_rx;	// Флаг - приняты данные

	// ЗАПИСЬ
	wire hi_1575_ready_tx;					// флаг, МК готова к передаче
	reg hi_1575_cha_chb_tx = 1'b0;			// выбор канала (0 - А, 1 - B) для передачи по МКИО
	reg [15 : 0] hi_1575_data_tx = 16'h0;	// данные для передачи для МК по МКИО
	reg hi_1575_command_word_tx = 1'b0;		// передаваемое слово является командным
	reg hi_1575_start_tx = 1'b0;			// Начать передачу данных
	
// На случай если HI-1575 зависнет
localparam HI_1575_RESET_TIME = 11'd1847;		// 18 мкСек
logic [10 : 0] reset_counter = 10'd0;		// счетчик для сброса (до 1024)
wire hi_1575_reset_n = (reset_counter >= HI_1575_RESET_TIME) ? (1'b0) : (1'b1);

always @(posedge clock_100 or negedge reset_b) begin
	if (~reset_b) begin
		reset_counter 	<= 11'd0;	// счетчик сброса HI-1575
	end
	else begin
		reset_counter	<= (pin_rcva | pin_rcvb | hi_1575_start_tx) ? (reset_counter + 11'd1) : (11'd0);
	end
end
									
hi_1575 hi_1575_inst
(
	.clock_100(clock_100),
	.clock_12(clock_12),
	.reset_b(reset_b & mkio_en & hi_1575_reset_n),

	.pin_rcva(pin_rcva),				
	.pin_rcvb(pin_rcvb),				
	.pin_reg(pin_reg),					
	.pin_r_w(pin_r_w),					
	.pin_strb_n(pin_strb_n),			
	.pin_mr(pin_mr),					
	.pin_sync(pin_sync),				
	.pin_d(pin_d),						
	.pin_clk_12(pin_clk_12),			
	.pin_cha_chb(pin_cha_chb),			
	//.pin_error(pin_error),				
	
// ЧТЕНИЕ
	.data_rx(hi_1575_data_rx),						// принятые данные
	.cha_chb_rx(hi_1575_cha_chb_rx),				// По какому каналу приняты данные (0 - А, 1 - B)
	.data_received_rx(hi_1575_data_received_rx),	// принято слово (1 - слово данных, 3 - командное слово)

// ЗАПИСЬ
	.ready_tx(hi_1575_ready_tx),				// флаг, что МК готов для передачи следующего слова
	.cha_chb_tx(hi_1575_cha_chb_tx),			// выбор канала (0 - А, 1 - B) для передачи
	.data_tx(hi_1575_data_tx),					// данные для передачи
	.command_word_tx(hi_1575_command_word_tx),	// передаваемое слово является командным
	.start_tx(hi_1575_start_tx)					// Начать передачу данных
);

// Модуль RAM для хранения данных для передачи по МКИО (Принятые по МКИО данные хранятся только для технологического теста ОУ)
	wire [4 : 0] mkio_ram_subaddress_tx = (mkio_master & ~mkio_master_cycle_mode) ? (5'd0) : (mkio_100_reg_tx[9 : 5]);	// Подадрес для формирования адреса записи в RAM (из h100-го регистра)
	wire [4 : 0] mkio_ram_subaddress_rx = (mkio_master) ? ((|mkio_master_subaddress) ? (mkio_master_subaddress) : (5'd1)) : (mkio_slave_subaddress);
	logic ram_w_r = 1'b1;	// 1 - Чтение с RAM, 0 - Запись в RAM
	logic ram_w_r_before = 1'b1;	// "ram_w_r" на предыдушем такте
	logic ram_read_ready = 1'b0;	// Сигнал, что можно считывать данные с RAM
	wire [10 : 0] ram_address_rx = {mkio_master, (mkio_ram_subaddress_rx - 5'd1), mkio_word_counter[4 : 0]};	// адрес для чтения с RAM
	logic [10 : 0] ram_address_tx = 11'h0;	// Для синхронной логики
	logic [5 : 0] ram_word_counter = 6'd0;	// Счетчик записанных слов в RAM
	logic ram_write_start = 1'b0;				// Сигнал для начала записи в RAM
	
	// ПОРТЫ ДЛЯ "ram_1_port"
		wire [10 : 0] ram_address = (ram_w_r) ? (ram_address_rx) : (ram_address_tx);
		logic [15 : 0] ram_data_tx = 16'h0;		// Данные для записи в RAM
		logic ram_write_en = 1'b0;				// Сигнал, по которому данные записываются в RAM
		wire [15 : 0] ram_data_rx;				// Данные считанные с RAM
		
ram_1_port	ram_1_port_inst 
(
	.clock (clock_100),
	
	.address(ram_address),
	.data(ram_data_tx),
	.wren(ram_write_en),
	
	.q(ram_data_rx)
);

// Запись данных в RAM
always @(posedge clock_100, negedge reset_b) begin
	if (~reset_b) begin
		ram_w_r 		<= 1'b1;	// 1 - Чтение с RAM, 0 - Запись в RAM
		ram_w_r_before	<= 1'b0;	// Сигнал, что можно считывать данные с RAM
		ram_word_counter 	<= 6'd0;	// Счетчик записанных слов в RAM
		ram_write_start <= 1'b0;	// Сигнал для записи в RAM
		ram_write_en 	<= 1'b0;	// Сигнал, по которому данные записываются в RAM
		ram_read_ready	<= 1'b0;	// Сигнал, что можно считывать данные с RAM
		
		ram_address_tx		<=	11'h0;	// адрес для записи в RAM
		ram_data_tx			<=	16'h0;	// Данные для записи в RAM
	end 
	else begin
		ram_w_r_before	<= ram_w_r;	// Для формирования "ram_read_ready"
		
		ram_read_ready	<= (ram_w_r & ram_w_r_before) ? (1'b1) : (1'b0);	// Сигнал, что можно считывать данные с RAM
		
		if (~ram_write_start) begin
			ram_w_r 			<= 1'b1;	// 1 - Чтение с RAM, 0 - Запись в RAM
			ram_word_counter 	<= 6'd0;	// Счетчик записанных слов в RAM
			ram_write_start		<= (|mkio_ram_subaddress_tx) ? (mkio_ram_write_sign) : (1'b0);	// Сигнал записи в RAM из внешнего модуля
			ram_write_en 		<= 1'b0;	// Сигнал, по которому данные записываются в RAM
		end
		else begin
			if (ram_word_counter <= 6'd31) begin
				ram_w_r 			<= 1'b0;		// 1 - Чтение с RAM, 0 - Запись в RAM
				ram_write_start		<= 1'b1;		// Сигнал записи в RAM
				ram_write_en 		<= ~ram_w_r;	// Сигнал, по которому данные записываются в RAM
				ram_word_counter	<= (ram_write_en) ? (ram_word_counter + 6'd1) : (ram_word_counter);
				
				ram_address_tx		<=	{mkio_master, (mkio_ram_subaddress_tx - 5'd1), ram_word_counter[4 : 0]};		// адрес для записи в RAM;	// адрес для записи в RAM
				ram_data_tx			<=	mkio_ram_data_words_tx[ram_word_counter[4 : 0]];	// Данные для записи в RAM				
			end
			else begin	// Обнуление
				ram_w_r 			<= 1'b1;	// 1 - Чтение с RAM, 0 - Запись в RAM
				ram_write_start		<= 1'b0;	// Сигнал записи в RAM
				ram_write_en 		<= 1'b0;	// Сигнал, по которому данные записываются в RAM
				ram_word_counter	<= 6'd0;
				
				ram_address_tx		<=	11'h0;	// адрес для записи в RAM
				ram_data_tx			<=	16'h0;	// Данные для записи в RAM	
			end
		end
	end
end

//-------------- Внутренние регистры и соединения

// СОСТОЯНИЯ
logic [3 : 0] state = 4'd0;

localparam 	IDLE 							= 4'd0,	// Если "mkio_en = 0"
			MKIO_WAIT_5						= 4'd1,	// задержка 5 мкСек перед отправкой ОС в режиме ОУ или КС в режиме КШ 
			MKIO_WAIT_AFTER_COMMAND_WORD_TX = 4'd2,	// задержка после отправки командного слова
			MKIO_WAIT_AFTER_DATA_WORD_TX	= 4'd3,	// задержка перед отправкой 2-го и последующих слов данных
	// Ветка ОУ
			MKIO_SLAVE_IDLE					= 4'd4,	
			MKIO_SLAVE_WORDS_RX				= 4'd5,
			MKIO_SLAVE_SEND_OS				= 4'd6,
			MKIO_SLAVE_WORDS_TX				= 4'd7,
	// Ветка КШ
			MKIO_MASTER_IDLE				= 4'd8,
			MKIO_MASTER_SEND_KS				= 4'd9,
			MKIO_MASTER_WORDS_TX			= 4'd10,
			MKIO_MASTER_RECEIVE_OS			= 4'd11,
			MKIO_MASTER_CHECK_OS			= 4'd12,
			MKIO_MASTER_WORDS_RX			= 4'd13,
			MKIO_MASTER_WAIT_5ms			= 4'd14;	// Состояние ожидания повторного обмена, если "абонент занят"
			
// ТАЙМИНГИ
	localparam	MKIO_WAIT_AFTER_COMMAND_WORD_TX_TIME = 'd1000,
				MKIO_WAIT_AFTER_DATA_WORD_TX_TIME = 'd1985,
				MKIO_WAIT_5_TIME = 'd550;	// Время ожидания 5 мкСек перед отправкой ОС/КС
	
	// КШ
	localparam 	MKIO_MASTER_WAIT_OS_TIME = 'd1500,			// Время ожидания перед приемом ОС (1 слово передается на линию МКИО - 20 мкСек)
				MKIO_MASTER_DELAY_OS_TIME_RX = 'd4250 + MKIO_MASTER_WAIT_OS_TIME,				// Время ожидания ответного слова в режиме КШ если чтение с ОУ
				MKIO_MASTER_DELAY_OS_TIME_TX = 'd5250 + MKIO_MASTER_WAIT_OS_TIME,				// Время ожидания ответного слова в режиме КШ если передача в ОУ
				MKIO_MASTER_WAIT_BEFORE_REPEAT_TIME = 'd500_000;	// Время ожидания повторного обмена, если "абонент занят" через 5 мСек

	logic [18 : 0] counter_10_ns = 19'd0;		// счетчик для 10 нСек при clock = 100 Мгц

// Вспомогательные регистры
	// Общие
		integer k;	// Переменная для циклов
		logic [5 : 0] mkio_word_counter = 6'd0;	// Счетчик принятых/переданных СД
	// ОУ
		logic [4 : 0] mkio_slave_subaddress = 5'd1;			// Подадрес, для которого запрошен обмен данными в режиме ОУ
		logic [5 : 0] mkio_slave_number_of_words = 6'd0;		// Количество слов, для которых запрошен обмен данными в режиме ОУ
		logic mkio_slave_ready = 1'b0;	//	Готовность ОУ к обмену в режиме ОУ
		logic [1 : 0] mkio_slave_command_word_format = 2'b0;	// Формат по которому будет обмен с КШ в режиме ОУ
			/*
				"mkio_slave_command_word_format == 2'b1" - Формат №1 сообщений МКИО (Принять СД в выбранный подадрес)
				"mkio_slave_command_word_format == 2'b2" - Формат №2 сообщений МКИО (Передать СД с выбранного подадреса)
			*/
		wire [15 : 0] mkio_slave_OS = {mkio_slave_address_internal, 11'b0};	// Ответное слово в режиме ОУ
	// КШ
		wire [4 : 0] mkio_master_address = mkio_100_reg_tx[15 : 11];				// Адрес ОУ для приема/передачи в режиме КШ
		wire [4 : 0] mkio_master_subaddress = (mkio_master_cycle_mode) ? (mkio_master_cycle_subaddress) : (mkio_100_reg_tx[9 : 5]);	// Подадрес в ОУ для приема/передачи в режиме КШ
		wire [5 : 0] mkio_master_number_of_words = (mkio_master_cycle_mode) ? (6'd32) : ((mkio_100_reg_tx[4 : 0]) ? ({1'b0, mkio_100_reg_tx[4 : 0]}) : (6'd32));	// Количество слов данных для приема/передачи в режиме КШ
		logic mkio_master_ready = 1'b0;	// готовность КШ к обмену в режиме КШ
		wire [15 : 0] mkio_master_KC = {mkio_master_address, mkio_master_w_r, mkio_master_subaddress, ((mkio_master_number_of_words == 6'd32) ? (5'd0) : (mkio_master_number_of_words[4 : 0]))}; // командное слово для "MKIO_MASTER_SEND_KS"
		
// Вспомогательные сигналы
assign mkio_ready = (mkio_en) ? ((mkio_master) ? (mkio_master_ready) : (mkio_slave_ready)) : (1'b0);	// Для Регистра F900

logic [1 : 0] hi_1575_word_received_rx_before = 2'b0;
always @(posedge clock_100, negedge reset_b)	
	if (!reset_b) 	hi_1575_word_received_rx_before <= 2'b0;
	else 			hi_1575_word_received_rx_before <= hi_1575_data_received_rx;

logic mkio_master_start_before = 1'b0;
always @(posedge clock_100, negedge reset_b)	
	if (!reset_b) 	mkio_master_start_before <= 1'b0;
	else 			mkio_master_start_before <= mkio_master_start;
	
logic pin_r_w_before = 1'b1;
always @(posedge clock_100, negedge reset_b)	
	if (!reset_b) 	pin_r_w_before <= 1'b1;
	else 			pin_r_w_before <= pin_r_w;


logic mkio_master_w_r_before = 1'b0;

// ОБЩИЕ
	logic hi_1575_data_sent_tx = 1'b0;	// Данные переданы
	logic mkio_data_received = 1'b0;	// Приняты данные по МКИО
	logic mkio_data_word_received = 1'b0;				// Принято новое слово данных
	logic mkio_command_word_received = 1'b0;			// Принято командное слово
// ОУ
	logic mkio_slave_command_word_received = 1'b0;	// Принято командное слово в режиме ОУ с ненулевым подадресом
		/*
		"&hi_1575_data_received_rx" - принято командное слово (hi_1575_data_received_rx = 2'b11)
		"hi_1575_data_rx[15 : 11] == mkio_slave_address_internal" - адрес совпадает с адресом ОУ
		"|hi_1575_data_rx[9 : 5]" - должен быть ненулевой подадрес (Защита от ложных КС)
		*/
// КШ
	logic mkio_master_new_exchange = 1'b0;	// Новый период обмена в режиме КШ
	logic mkio_master_cycle_mode_rx_delay = 1'b0;	// Сигнал на задержку, если чтение, чтобы данные успели передаться по ETH

always @(negedge clock_100 or negedge reset_b) begin
	if(~reset_b) begin
// ОБЩИЕ
		hi_1575_data_sent_tx <= 1'b0;	// Данные переданы
		mkio_data_received <= 1'b0;	// Приняты данные по МКИО
		mkio_data_word_received <= 1'b0;				// Принято новое слово данных
		mkio_command_word_received <= 1'b0;			// Принято командное слово
	// ОУ
		mkio_slave_command_word_received <= 1'b0;	// Принято командное слово в режиме ОУ с ненулевым подадресом
			/*
			"&hi_1575_data_received_rx" - принято командное слово (hi_1575_data_received_rx = 2'b11)
			"hi_1575_data_rx[15 : 11] == mkio_slave_address_internal" - адрес совпадает с адресом ОУ
			"|hi_1575_data_rx[9 : 5]" - должен быть ненулевой подадрес (Защита от ложных КС)
			*/
	// КШ
		mkio_master_new_exchange <= 1'b0;	// Новый период обмена в режиме КШ
		mkio_master_cycle_mode_rx_delay <= 1'b1;
	end
	else begin
	// ОБЩИЕ
		hi_1575_data_sent_tx <= (~pin_r_w_before & pin_r_w);	// Данные переданы
		mkio_data_received <= (~hi_1575_word_received_rx_before[0] & hi_1575_data_received_rx[0]);	// Приняты данные по МКИО
		mkio_data_word_received <= (mkio_data_received & ~hi_1575_data_received_rx[1]);				// Принято новое слово данных
		mkio_command_word_received <= (mkio_data_received & hi_1575_data_received_rx[1]);			// Принято командное слово
	// ОУ
		mkio_slave_command_word_received <= (~mkio_master) ? (mkio_command_word_received & (hi_1575_data_rx[15 : 11] == mkio_slave_address_internal) & (|hi_1575_data_rx[9 : 5])) : (1'b0);	// Принято командное слово в режиме ОУ с ненулевым подадресом
			/*
			"&hi_1575_data_received_rx" - принято командное слово (hi_1575_data_received_rx = 2'b11)
			"hi_1575_data_rx[15 : 11] == mkio_slave_address_internal" - адрес совпадает с адресом ОУ
			"|hi_1575_data_rx[9 : 5]" - должен быть ненулевой подадрес (Защита от ложных КС)
			*/
	// КШ
		mkio_master_new_exchange <= (mkio_master) ? (~mkio_master_start_before & mkio_master_start) : (1'b0);	// Новый период обмена в режиме КШ
		mkio_master_cycle_mode_rx_delay <= (mkio_master_cycle_mode & mkio_master_w_r_before & mkio_master_w_r) ? (|mkio_master_cycle_subaddress) : (1'b0);	// Сигнал на задержку, если чтение, чтобы данные успели передаться по ETH
	end
end

// Формирование регистра F900
	assign mkio_status[2] = mkio_slave_ready;
	assign mkio_status[1 : 0] = (mkio_ready) ? (2'b00) : ((pin_cha_chb) ? (2'b10) : (2'b01));

// КОНЕЧНЫЙ АВТОМАТ МКИО
always @(posedge clock_100, negedge reset_b) begin
	if (!reset_b) begin
		// ОБЩИЕ
			mkio_FA00_reg_rx		<= 16'h0;
			mkio_ready_rx 			<= 1'b0;	// 1 - приняты данные по МКИО
			mkio_word_counter 		<= 6'd0;	// Счетчик принятых/переданных СД
			
			for (k = 0; k <= 31; k = k + 1)
				mkio_data_words_rx[k] <= 16'h0;	// Буфер полученных слов данных
				
			counter_10_ns 		<= 19'd0;		// счетчик для 10 нСек
			// HI-1575
				hi_1575_cha_chb_tx 			<= 1'b0;	// выбор канала (0 - А, 1 - B) для передачи по МКИО
				hi_1575_data_tx 			<= 16'h0;	// данные для передачи для МК по МКИО
				hi_1575_command_word_tx 	<= 1'b0;	// передаваемое слово является командным
				hi_1575_start_tx 			<= 1'b0;	// Начать передачу данных
		// ОУ
			mkio_slave_ready 				<= 1'b0;	// Готовность ОУ к обмену в режиме ОУ
			mkio_slave_command_word_format 	<= 2'b0;	// Формат КС принятого в режиме ОУ
			mkio_slave_subaddress 		<= 5'd1;	// Подадрес для которого получены данные в режиме ОУ
			mkio_slave_number_of_words 	<= 6'd0;	// Количество слов данных полученных в режиме ОУ		
		// КШ
			mkio_master_exchange_error_counter 	<= 3'd0;	// Счетчик неудачных попыток обмена с ОУ в режиме КШ
			mkio_master_ready					<= 1'b0;	// 1 - КШ готов для команд обмена
		
		// Переход
			state <= IDLE;
	end
	else begin
		case (state)
			
// Общая ветка
			IDLE: begin	// 0	
				// ОБЩИЕ
					mkio_FA00_reg_rx		<= 16'h0;
					mkio_ready_rx 			<= 1'b0;	// 1 - приняты данные по МКИО
					mkio_word_counter 		<= 6'd0;	// Счетчик принятых/переданных СД
					
					for (k = 0; k <= 31; k = k + 1)
						mkio_data_words_rx[k] <= 16'h0;	// Буфер полученных слов данных
						
					counter_10_ns 		<= 19'd0;		// счетчик для 10 нСек
					// HI-1575
						hi_1575_cha_chb_tx 			<= 1'b0;	// выбор канала (0 - А, 1 - B) для передачи по МКИО
						hi_1575_data_tx 			<= 16'h0;	// данные для передачи для МК по МКИО
						hi_1575_command_word_tx 	<= 1'b0;	// передаваемое слово является командным
						hi_1575_start_tx 			<= 1'b0;	// Начать передачу данных
				// ОУ
					mkio_slave_ready 				<= 1'b0;	// Готовность ОУ к обмену в режиме ОУ
					mkio_slave_command_word_format 	<= 2'b0;	// Формат КС принятого в режиме ОУ
					mkio_slave_subaddress 		<= 5'd1;	// Подадрес для которого получены данные в режиме ОУ
					mkio_slave_number_of_words 	<= 6'd0;	// Количество слов данных полученных в режиме ОУ		
				// КШ
					mkio_master_exchange_error_counter 	<= 3'd0;	// Счетчик неудачных попыток обмена с ОУ в режиме КШ
					mkio_master_ready					<= 1'b0;	// 1 - КШ готов для команд обмена
				
				// Переход
					state <= (mkio_en) ? ((mkio_master) ? (MKIO_MASTER_IDLE) : (MKIO_SLAVE_IDLE)) : (IDLE);
			end

// ВЕТКА ОУ		
			MKIO_SLAVE_IDLE: begin	// 1	
				if (mkio_slave_command_word_received) begin
					mkio_slave_ready 				<= 1'b0;	// Готовность ОУ к обмену в режиме ОУ
					
					mkio_slave_subaddress 		<= hi_1575_data_rx[9 : 5];	// Принятый подадрес
					mkio_slave_number_of_words	<= (hi_1575_data_rx[4 : 0]) ? ({1'b0, hi_1575_data_rx[4 : 0]}) : (6'd32);	// количество слов, которое надо принять/передать (0 - 32 слова)
					mkio_word_counter 			<= 6'd0;		// Счетчик принятых/переданных СД обнуляем
					
					hi_1575_cha_chb_tx			<= hi_1575_cha_chb_rx;	// В "MKIO_SLAVE_SEND_OS" Будем отправлять ОС на тот канал, по которому принято командное слово
					
					mkio_slave_command_word_format <= (hi_1575_data_rx[10]) ? (2'd2) : (2'd1);	// Для "MKIO_SLAVE_SEND_OS"
					
					counter_10_ns	<= 19'd0;	// счетчик для 10 нСек
					
					if (~hi_1575_data_rx[10]) begin	// Если нужно ПРИНЯТЬ СД по формату №1 (тоже, что и "mkio_slave_command_word_format", но без задержки на такт)
						mkio_ready_rx 			<= 1'b0;		// Будут приняты новые данные
						
						for (k = 0; k <= 31; k = k + 1)
							mkio_data_words_rx[k] <= 16'h0;		// Буфер слов данных, полученных в режиме ОУ обнуляем
						
						// Переход
							state <= MKIO_SLAVE_WORDS_RX;
					end
					else begin	// Если нужно будет после ОС ПЕРЕДАТЬ СД по формату №2
						hi_1575_data_tx 			<= 16'h0;	// данные для передачи для МК по МКИО
						hi_1575_command_word_tx 	<= 1'b0;	// передаваемое слово является командным
						hi_1575_start_tx 			<= 1'b0;	// Начать передачу данных
						
						// Переход
							state <= MKIO_WAIT_5;	// через 5 мкСек передача ОС
					end
				end
				else begin
					mkio_slave_ready 			<= 1'b1;	// Готовность ОУ к обмену в режиме ОУ
					
					hi_1575_data_tx 			<= 16'h0;	// данные для передачи для МК по МКИО
					hi_1575_command_word_tx 	<= 1'b0;	// передаваемое слово является командным
					hi_1575_start_tx 			<= 1'b0;	// Начать передачу данных
					
					mkio_slave_command_word_format 	<= 2'b0;	// Формат КС принятого в режиме ОУ
					mkio_word_counter 				<= 6'd0;	// Счетчик принятых/переданных СД
					
					mkio_master_ready				<= 1'b0;	// 0 - КШ не готов для передачи данных
					counter_10_ns 					<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= (mkio_en) ? ((mkio_master) ? (MKIO_MASTER_IDLE) : (MKIO_SLAVE_IDLE)) : (IDLE);
				end
			end
			
			MKIO_SLAVE_WORDS_RX: begin	// 2	
				if (mkio_word_counter < mkio_slave_number_of_words) begin	// Пока не получили все слова
					if (mkio_data_word_received) begin
						mkio_data_words_rx[mkio_word_counter] <= hi_1575_data_rx;	// Записываем полученное СД
						mkio_word_counter	<= mkio_word_counter + 6'd1;	// Увеличиваем счетчик полученных СД
					end
					
						counter_10_ns	<= (mkio_data_word_received) ? (19'd0) : (counter_10_ns + 19'd1);	// На случай ошибки
					
					// Переход
						state <= (counter_10_ns < (MKIO_WAIT_AFTER_DATA_WORD_TX_TIME + 19'd5040)) ? (MKIO_SLAVE_WORDS_RX) : (MKIO_SLAVE_IDLE);	// На случай если СД так и не пришло			
				end
				else begin
					mkio_FA00_reg_rx		<= {mkio_slave_address, 1'b0, mkio_slave_subaddress, ((mkio_slave_number_of_words == 6'd32) ? (5'd0) : (mkio_slave_number_of_words[4 : 0]))};
					mkio_ready_rx 			<= 1'b1;	// Приняты новые данные
					mkio_word_counter		<= 6'd0;	// Счетчик принятых СД обнуляем
					
					counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= MKIO_WAIT_5;
				end
			end
			
			MKIO_SLAVE_SEND_OS: begin	// 4
				if (~hi_1575_data_sent_tx) begin	// пока не получим сигнал, что данные были отправлены
					hi_1575_data_tx 			<= mkio_slave_OS;		// ОС для передачи для МК по МКИО
					hi_1575_command_word_tx 	<= 1'b1;				// передаваемое слово является командным
				 // hi_1575_cha_chb_tx			<= hi_1575_cha_chb_rx;	// Сформировано В "MKIO_SLAVE_IDLE"
					hi_1575_start_tx 			<= 1'b1;	// Начать передачу ОС
					
						counter_10_ns	<= counter_10_ns + 19'd1;	// На случай если МК зависнет 
					
					// Переход
						state <= (counter_10_ns < 10'd1000) ? (MKIO_SLAVE_SEND_OS) : (MKIO_SLAVE_IDLE);	// На случай если МК зависнет
				end
				else begin
					hi_1575_start_tx 			<= 1'b0;		// Останавливаем передачу передачу ОС
					hi_1575_data_tx 			<= 16'h0;		// Обнуляем данные для передачи
					hi_1575_command_word_tx 	<= 1'b0;		// Обнуляем флаг командного слова
					mkio_word_counter			<= 6'd0;		// Счетчик принятых/переданных СД обнуляем
					
						counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= (mkio_slave_command_word_format == 2'b1) ? (MKIO_SLAVE_IDLE) : (MKIO_WAIT_AFTER_COMMAND_WORD_TX);	
				end
			end
						
			MKIO_SLAVE_WORDS_TX: begin	// 5
				if (~hi_1575_data_sent_tx) begin
					hi_1575_data_tx 			<= (~usb_test_on) ? (ram_data_rx) : (mkio_data_words_rx[mkio_word_counter]);	// Передаем данные с RAM или то что получили, если технологический режим
					//hi_1575_data_tx 			<= (mkio_data_words_rx[mkio_word_counter]);	// Передаем данные с RAM или то что получили, если технологический режим
					hi_1575_command_word_tx 	<= 1'b0;	// передаваемое слово НЕ является командным
					hi_1575_start_tx			<= (ram_read_ready) ? (1'b1) : (1'b0);	// Начать передачу, если данные с RAM готовы для считывания
					
						counter_10_ns	<= counter_10_ns + 19'd1;	// На случай если МК зависнет 
					
					// Переход
						state <= (counter_10_ns < 10'd1000) ? (MKIO_SLAVE_WORDS_TX) : (MKIO_SLAVE_IDLE);	// На случай если МК зависнет
				end
				else begin
					hi_1575_start_tx 			<= 1'b0;						// Останавливаем передачу
					mkio_word_counter			<= mkio_word_counter + 6'd1;	// Счетчик принятых/переданных СД обнуляем
					
						counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
							state <= ((mkio_word_counter + 6'd1) >= mkio_slave_number_of_words) ? (MKIO_SLAVE_IDLE) : (MKIO_WAIT_AFTER_DATA_WORD_TX);	// "mkio_word_counter + 6'd1" чтобы не задерживать на такт		
				end
			end

// ВЕТКА КШ			
			MKIO_MASTER_IDLE: begin	// 6
				hi_1575_start_tx 					<= 1'b0;	// Передаем команду на передачу МК
				
				mkio_master_ready					<= (|mkio_master_exchange_error_counter) ? (1'b0) : (1'b1);	// КШ готов к новому обмену если предыдуший обмен был УДАЧНЫЙ
				mkio_master_exchange_error_counter	<= (~mkio_master_start) ? (3'd0) : (mkio_master_exchange_error_counter);	// Обнуляем счетчик неудачных попыток, если сбросили сигнал обмена
				
				mkio_slave_ready 		<= 1'b0;	// Готовность ОУ к обмену в режиме ОУ
				
				if (((mkio_master_start && (mkio_master_exchange_error_counter < 3'd6)) || mkio_master_new_exchange) && (mkio_master_subaddress)) begin	// если подадрес для обмена НЕНУЛЕВОЙ
					mkio_ready_rx 			<= (mkio_master_w_r) ? (1'b0) : (mkio_ready_rx);		// Будут приняты новые данные
					
					counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= (hi_1575_ready_tx) ? (MKIO_MASTER_SEND_KS) : (MKIO_MASTER_IDLE);
				end
				else begin
					counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= (mkio_en) ? ((mkio_master) ? (MKIO_MASTER_IDLE) : (MKIO_SLAVE_IDLE)) : (IDLE);
				end
			end	
	
			MKIO_MASTER_SEND_KS: begin	// 7
				mkio_master_ready <= 1'b0;	// КШ начинает обмен
				
				if (~hi_1575_data_sent_tx) begin
					hi_1575_data_tx			<= mkio_master_KC;	// КС для передачи
					hi_1575_command_word_tx	<= 1'b1;	// Командное слово
					hi_1575_cha_chb_tx		<= (mkio_master_exchange_error_counter < 3) ? (1'b0) : (1'b1);	// Если было 3 неудачные попытки обмена по каналу "А", то переходим на "B"
					hi_1575_start_tx 		<= (hi_1575_ready_tx) ? (1'b1) : (1'b0);						// Передаем команду на передачу МК
					
						counter_10_ns	<= counter_10_ns + 19'd1;	// На случай если МК зависнет 
					
					// Переход
						state <= (counter_10_ns < 10'd1000) ? (MKIO_MASTER_SEND_KS) : (MKIO_MASTER_IDLE);	// На случай если МК зависнет
				end
				else begin	
					// Обнуляем
					hi_1575_data_tx			<= 16'h0;	// КС для передачи
					hi_1575_command_word_tx	<= 1'b0;	// Командное слово
					hi_1575_start_tx 		<= 1'b0;	// Передаем команду на передачу МК
					mkio_word_counter 		<= 6'd0;	// Счетчик принятых/переданных СД обнуляем
					
						counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= (mkio_master_w_r) ? (MKIO_MASTER_RECEIVE_OS) : (MKIO_WAIT_AFTER_COMMAND_WORD_TX);	// 1 - прием СД, 0 - передача СД
				end
			end
			
			MKIO_MASTER_WORDS_TX: begin	// 8
				if (~hi_1575_data_sent_tx) begin
					hi_1575_data_tx 			<= (mkio_master_cycle_mode) ? (ram_data_rx) : (mkio_ram_data_words_tx[mkio_word_counter]);	// Передаем данные с RAM или напрямую с буфера если асихронный режим
					hi_1575_command_word_tx 	<= 1'b0;	// передаваемое слово НЕ является командным
					hi_1575_start_tx			<= (ram_read_ready) ? (1'b1) : (1'b0);	// Начать передачу, если данные с RAM готовы для считывания
					
						counter_10_ns	<= counter_10_ns + 19'd1;	// На случай если МК зависнет 
					
					// Переход
						state <= (counter_10_ns < 10'd1000) ? (MKIO_MASTER_WORDS_TX) : (MKIO_MASTER_IDLE);	// На случай если МК зависнет
				end
				else begin
					hi_1575_start_tx 			<= 1'b0;						// Останавливаем передачу передачу
					mkio_word_counter			<= mkio_word_counter + 6'd1;	// Счетчик принятых/переданных СД обнуляем
					
						counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= MKIO_WAIT_AFTER_DATA_WORD_TX;	//		
				end
			end			

			MKIO_MASTER_RECEIVE_OS: begin	// 10
				if (mkio_data_received & hi_1575_data_received_rx[1]) begin	// Если приняты данные с pin_sync=1 (командное слово)
					counter_10_ns <= counter_10_ns + 19'd1;	// счетчик состояния
					
					// Переход
						state <= MKIO_MASTER_CHECK_OS;
				end
				else begin
					if (counter_10_ns < ((mkio_master_w_r ) ? (MKIO_MASTER_DELAY_OS_TIME_RX) : (MKIO_MASTER_DELAY_OS_TIME_TX))) begin
						counter_10_ns <= counter_10_ns + 19'd1;	// счетчик состояния
						
						// Переход
							state <= MKIO_MASTER_RECEIVE_OS;						
					end
					else begin	// Если время ожидания ОС вышло
						mkio_master_exchange_error_counter 	<= mkio_master_exchange_error_counter + 3'd1; // увеличиваем счетчик неудачных попыток
						
						mkio_master_w_r_before	<= 1'b0;
						
						counter_10_ns <= 19'd0;	// счетчик состояния
							
						// Переход
							state <= MKIO_WAIT_5;
					end
				end
			end
			
			MKIO_MASTER_CHECK_OS: begin
				if ((hi_1575_data_rx[15 : 11] == mkio_master_address) & ~(|hi_1575_data_rx[9 : 5])) begin
				
					counter_10_ns <= 19'd0;	// счетчик состояния
					
					if (hi_1575_data_rx[10] | hi_1575_data_rx[3] | hi_1575_data_rx[2] | hi_1575_data_rx[0]) begin // В ответном слове информация об ошибках
						mkio_master_exchange_error_counter 	<= mkio_master_exchange_error_counter + 3'd1; // увеличиваем счетчик неудачных попыток
						
						mkio_master_w_r_before	<= 1'b0;
						
						// Переход
							state <= (hi_1575_data_rx[3]) ? (MKIO_MASTER_WAIT_5ms) : (MKIO_WAIT_5);	// hi_1575_data_rx[3] - абонент занят (Повтор обмена через 5 мСек)					
					end
					else begin	// Если все в норме
						mkio_master_exchange_error_counter 	<= 3'd0;	// обнуляем счетчик неудачных попыток обмена
						
						mkio_master_w_r_before	<= mkio_master_w_r;
						
						// Переход
							state <= (mkio_master_w_r) ? (MKIO_MASTER_WORDS_RX) : (MKIO_WAIT_5);
					end
				end
				else begin	// Если ложное ответное слово
					counter_10_ns <= counter_10_ns + 19'd1;	// счетчик состояния
					
					// Переход
						state <= MKIO_MASTER_RECEIVE_OS;
				end
			end
			
			MKIO_MASTER_WORDS_RX: begin	// 11	
				if (mkio_word_counter < mkio_master_number_of_words) begin	// Пока не получили все слова
					if (mkio_data_word_received) begin
						mkio_data_words_rx[mkio_word_counter] <= hi_1575_data_rx;	// Записываем полученное СД
						mkio_word_counter	<= mkio_word_counter + 6'd1;	// Увеличиваем счетчик полученных СД
					end
					
						counter_10_ns	<= (mkio_data_word_received) ? (19'd0) : (counter_10_ns + 19'd1);	// На случай ошибки
					
					// Переход
						if (counter_10_ns < (MKIO_WAIT_AFTER_DATA_WORD_TX_TIME + 19'd5040)) begin
							state <= MKIO_MASTER_WORDS_RX;
						end
						else begin	// Если СД так и не пришло
							mkio_master_exchange_error_counter 	<= mkio_master_exchange_error_counter + 3'd1; // увеличиваем счетчик неудачных попыток
							
							state <= MKIO_MASTER_IDLE;	// На случай если СД так и не пришло
						end					
				end
				else begin
					mkio_FA00_reg_rx		<= {mkio_master_address, 1'b0, mkio_master_subaddress, ((mkio_master_number_of_words == 6'd32) ? (5'd0) : (mkio_master_number_of_words[4 : 0]))};
					mkio_master_exchange_error_counter 	<= 3'd0; // успешный обмен
					
					mkio_ready_rx 			<= 1'b1;	// Приняты новые данные
					mkio_word_counter		<= 6'd0;	// Счетчик принятых СД обнуляем
					
					counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= MKIO_WAIT_5;
				end
			end
			
// ЗАДЕРЖКИ
			MKIO_WAIT_5: begin	// 3
				mkio_master_ready					<= (|mkio_master_exchange_error_counter) ? (1'b0) : (1'b1);	// КШ готов к новому обмену если предыдуший обмен был УДАЧНЫЙ
				mkio_master_exchange_error_counter	<= (~mkio_master_start) ? (3'd0) : (mkio_master_exchange_error_counter);	// Обнуляем счетчик неудачных попыток, если сбросили сигнал обмена
				
				if (counter_10_ns < ((mkio_master_cycle_mode_rx_delay) ? (19'd15_000) : (MKIO_WAIT_5_TIME))) begin	// 19'd160_000	//19'd35_000
					counter_10_ns <= counter_10_ns + 19'd1;	// счетчик состояния
					
					// Переход
						state <= MKIO_WAIT_5;
				end
				else begin
					counter_10_ns <= 19'd0;	// счетчик состояния
					
					// Переход
						state <= (mkio_master) ? (MKIO_MASTER_IDLE) : (MKIO_SLAVE_SEND_OS);
				end
			end
			
			MKIO_WAIT_AFTER_COMMAND_WORD_TX: begin	// 13
				if (counter_10_ns < MKIO_WAIT_AFTER_COMMAND_WORD_TX_TIME) begin	
					counter_10_ns	<= counter_10_ns + 19'd1;
					
					// Переход
						state <= MKIO_WAIT_AFTER_COMMAND_WORD_TX;
				end
				else begin
					counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= (mkio_master) ? (MKIO_MASTER_WORDS_TX) : (MKIO_SLAVE_WORDS_TX);
				end
			end
			
			MKIO_WAIT_AFTER_DATA_WORD_TX: begin	// 14
				if (counter_10_ns < MKIO_WAIT_AFTER_DATA_WORD_TX_TIME) begin	
					counter_10_ns	<= counter_10_ns + 19'd1;
					
					// Переход
						state <= MKIO_WAIT_AFTER_DATA_WORD_TX;
				end
				else begin
					counter_10_ns 			<= 19'd0;	// счетчик для 10 нСек
					
					// Переход
						state <= (mkio_master) ? ((mkio_word_counter < mkio_master_number_of_words) ? (MKIO_MASTER_WORDS_TX) : (MKIO_MASTER_RECEIVE_OS)) : (MKIO_SLAVE_WORDS_TX);
				end
			end
			
			MKIO_MASTER_WAIT_5ms: begin	// 12 - Соятояние ожидания повторного обмена, если "абонент занят"
				if (counter_10_ns < MKIO_MASTER_WAIT_BEFORE_REPEAT_TIME) begin
					counter_10_ns <= counter_10_ns + 19'd1;	// счетчик состояния
					
					// Переход
						state <= MKIO_MASTER_WAIT_5ms;
				end
				else begin
					counter_10_ns <= 19'd0;	// счетчик состояния
					
					// Переход
						state <= MKIO_MASTER_IDLE;
				end
			end
			
			default: 
					//переход
						state <= IDLE;
		endcase		
	end
end

// Для технологического режима
wire [4 : 0] mkio_slave_address_internal = (~usb_test_on) ? (mkio_slave_address) : (5'd1);	//  технологическом режиме используется 1 адрес ОУ

endmodule