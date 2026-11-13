#pragma once

#include <condition_variable>
#include <functional>
#include <mutex>
#include <queue>
#include <thread>

namespace meeting {

class SerialExecutor {
 public:
  SerialExecutor();
  ~SerialExecutor();

  SerialExecutor(const SerialExecutor&) = delete;
  SerialExecutor& operator=(const SerialExecutor&) = delete;

  void post(std::function<void()> task);
  void stop();

 private:
  void run();

  std::mutex mutex_;
  std::condition_variable condition_;
  std::queue<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread worker_;
};

}  // namespace meeting
