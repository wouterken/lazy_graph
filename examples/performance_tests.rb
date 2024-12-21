require 'vernier'
require 'memory_profiler'
require 'benchmark/ips'
require 'lazy_graph'

class PerformanceBuilder < LazyGraph::Builder
  rules_module :performance, {} do
    integer :employees_count, rule: { inputs: 'employees', calc: 'employees.size' }

    array :employees, required: true do
      string :id
      array :positions, required: true, default: [] do
        string :pay_schedule_id, invisible: true
        string :position_id, invisible: true

        object :position, rule: :"$.positions[position_id]"
        object :pay_schedule, rule: :'pay_schedules[pay_schedule_id]'
        number :pay_rate, rule: :"${position.pay_rate}"
        string :employee_id, rule: :"${id}"
      end
    end

    object :positions do
      object :".*", pattern_property: true do
        number :pay_rate
        number :salary, default: 100_000
      end
    end

    object :pay_schedules do
      object :".*", pattern_property: true do
        string :payment_frequency, enum: %w[weekly biweekly semi-monthly monthly],
                                   description: 'Payment frequency for this pay schedule.'
      end
    end
  end
end

def gen_employees(n, m = 10)
  {
    employees: n.times.map do |i|
      {
        id: i.to_s,
        positions: Random.rand(0..4).times.map do
          {
            position_id: Random.rand(1...10).to_s,
            pay_schedule_id: Random.rand(1...10).to_s
          }
        end
      }
    end,
    pay_schedules: [*1..m].map do |i|
      [i, {
        payment_frequency: %w[monthly weekly].sample
      }]
    end.to_h,
    positions: [*1..m].map do |i|
      [i, {
        pay_rate: Random.rand(10..100)
      }]
    end.to_h
  }
end

def profile_n(n, debug: false, validate: false)
  employees = gen_employees(n)
  graph = PerformanceBuilder.performance.build!(debug: debug, validate: validate)
  Vernier.profile(out: './examples/time_profile.json') do
    start = Time.now
    graph.context(employees).get('')
    ends = Time.now
    puts "Time elapsed: #{ends - start}"
  end
end

def memory_profile_n(n, debug: false, validate: false)
  employees = gen_employees(n)
  graph = PerformanceBuilder.performance.build!(debug: debug, validate: validate)
  report = MemoryProfiler.report do
    graph.context(employees).get('')
  end
  report.pretty_print
end

def benchmark_ips_n(n, debug: false, validate: false)
  graph = PerformanceBuilder.performance.build!(debug: debug, validate: validate)
  employees = gen_employees(n)
  Benchmark.ips do |x|
    x.report('performance') do
      graph.context(employees).get('')
    end
    x.compare!
  end
end

def console_n(n, debug: false, validate: false)
  graph = PerformanceBuilder.performance.build!(debug: debug, validate: validate)
  employees = gen_employees(n)
  result = graph.context(employees).get('')
  binding.b
end

case ARGV[0]
when 'ips' then benchmark_ips_n(ARGV.fetch(1, 1000).to_i)
when 'memory' then memory_profile_n(ARGV.fetch(1, 1000).to_i)
when 'console' then console_n(ARGV.fetch(1, 1000).to_i, debug: true)
when 'profile' then profile_n(ARGV.fetch(1, 100_000).to_i)
else nil
end
