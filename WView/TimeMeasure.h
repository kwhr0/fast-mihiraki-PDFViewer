#include <mach/mach_time.h>
#include <string>

class TM {
public:
	TM(const char *_label = "time") {
		label = _label;
		timebase.denom = 0;
	}
	void start() {
		if (!timebase.denom) mach_timebase_info(&timebase);
		time = mach_absolute_time();
	}
	void stop() {
		if (timebase.denom)
			printf("%s: %.3fmS\n", label.c_str(), 1e-6 * (mach_absolute_time() - time) * timebase.numer / timebase.denom);
	}
private:
	std::string label;
	mach_timebase_info_data_t timebase;
	uint64_t time;
};
